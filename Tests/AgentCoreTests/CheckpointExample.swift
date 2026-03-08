import AgentCore
import Foundation
import PiAI
import Testing

// MARK: - Example 2: Tool Checkpointing and Crash Recovery

/// Demonstrates the ``ToolActionSink`` and ``ToolCallResolution``
/// mechanisms. A "long bash" tool emits intermediate checkpoint
/// actions via the sink. The loop serializes and applies each
/// checkpoint action, so observers see progress in real time and
/// the state survives crashes.
///
/// Two recovery strategies are shown:
/// - **Error recovery**: inject an error with the last checkpoint
/// - **Resume recovery**: reconnect and continue execution

// MARK: State

struct CheckpointState: Sendable, Equatable {
  var messages: [Message] = []
  var toolStatus: [String: ToolCallStatus] = [:]
  var toolCheckpoints: [String: String] = [:]
  var hasWork: Bool = false
}

// MARK: Actions

enum CheckpointAction: Sendable, Equatable {
  case messagesUpdated([Message])
  case toolStatusUpdated(id: String, status: ToolCallStatus)
  case toolCheckpointed(id: String, output: String)
  case workFlagUpdated(Bool)
}

enum CheckpointExternalAction: Sendable {
  case enqueue(String)
}

struct CheckpointToolResult: Sendable, Hashable {
  var output: String
}

// MARK: Behavior

final class CheckpointBehavior: AgentBehavior, Sendable {
  typealias StreamAction = String

  let store: TestStore<CheckpointState>
  let responses: TestStore<[AssistantMessage]>
  private let callIndex = TestStore(0)

  let bashChunks: [String]
  let crashAfterChunks: Int?
  let recoveryMode: RecoveryMode

  enum RecoveryMode: Sendable {
    case errorWithCheckpoint
    case resume
  }

  init(
    mockResponses: [AssistantMessage] = [],
    bashChunks: [String] = ["chunk1\n", "chunk2\n", "chunk3\n"],
    crashAfterChunks: Int? = nil,
    recoveryMode: RecoveryMode = .errorWithCheckpoint,
    initialState: CheckpointState = .init()
  ) {
    self.responses = TestStore(mockResponses)
    self.bashChunks = bashChunks
    self.crashAfterChunks = crashAfterChunks
    self.recoveryMode = recoveryMode
    self.store = TestStore(initialState)
  }

  static var emptyState: CheckpointState { .init() }

  func loadState() async throws -> CheckpointState { store.value }

  func apply(_ action: CheckpointAction, to state: inout CheckpointState) {
    switch action {
    case let .messagesUpdated(msgs): state.messages = msgs
    case let .toolStatusUpdated(id, status): state.toolStatus[id] = status
    case let .toolCheckpointed(id, output): state.toolCheckpoints[id] = output
    case let .workFlagUpdated(flag): state.hasWork = flag
    }
  }

  func handle(_ action: CheckpointExternalAction, state: CheckpointState) async throws -> [CheckpointAction] {
    switch action {
    case let .enqueue(text):
      let msgs = store.withLock { s -> [Message] in
        s.messages.append(.user(text))
        s.hasWork = true
        return s.messages
      }
      return [.messagesUpdated(msgs), .workFlagUpdated(true)]
    }
  }

  func drainInterruptItems(state: CheckpointState) async throws -> [CheckpointAction] { [] }

  func drainTurnItems(state: CheckpointState) async throws -> [CheckpointAction] {
    guard state.hasWork else { return [] }
    store.withLock { $0.hasWork = false }
    return [.workFlagUpdated(false)]
  }

  func buildContext(state: CheckpointState) -> Context {
    Context(messages: state.messages)
  }

  func infer(context: Context, stream: AgentStreamSink<String>) async throws -> AssistantMessage {
    let idx = callIndex.withLock { i -> Int in let v = i; i += 1; return v }
    let all = responses.value
    guard idx < all.count else { throw AgentLoopError.inferenceProducedNoResult }
    return all[idx]
  }

  func persistAssistantEntry(_ message: AssistantMessage, state: CheckpointState) async throws -> [CheckpointAction] {
    let msgs = store.withLock { s -> [Message] in
      s.messages.append(.assistant(message))
      return s.messages
    }
    return [.messagesUpdated(msgs)]
  }

  func toolWillExecute(_ call: ToolCall, state: CheckpointState) async throws -> [CheckpointAction] {
    store.withLock { $0.toolStatus[call.id] = .started }
    return [.toolStatusUpdated(id: call.id, status: .started)]
  }

  func executeToolCall(
    _ call: ToolCall,
    sink: ToolActionSink<CheckpointAction>,
    resolution: ToolCallResolution
  ) async throws -> CheckpointToolResult {
    switch resolution {
    case .fresh:
      var output = ""
      for (i, chunk) in bashChunks.enumerated() {
        if let crashAfter = crashAfterChunks, i >= crashAfter {
          throw CancellationError()
        }
        output += chunk
        let snapshot = output
        store.withLock { $0.toolCheckpoints[call.id] = snapshot }
        await sink.emit(.toolCheckpointed(id: call.id, output: snapshot))
      }
      return CheckpointToolResult(output: output)

    case .fromPreviousLifetime:
      switch recoveryMode {
      case .errorWithCheckpoint:
        let lastCheckpoint = store.withLock { $0.toolCheckpoints[call.id] ?? "(no output)" }
        throw CheckpointRecoveryError(partialOutput: lastCheckpoint)
      case .resume:
        let existing = store.withLock { $0.toolCheckpoints[call.id] ?? "" }
        let output = existing + "resumed-output\n"
        store.withLock { $0.toolCheckpoints[call.id] = output }
        await sink.emit(.toolCheckpointed(id: call.id, output: output))
        return CheckpointToolResult(output: output)
      }
    }
  }

  func appendText(_ text: String, to result: CheckpointToolResult) -> CheckpointToolResult {
    CheckpointToolResult(output: result.output + text)
  }

  func toolDidExecute(_ call: ToolCall, result: CheckpointToolResult, state: CheckpointState) async throws -> [CheckpointAction] {
    let msgs = store.withLock { s -> [Message] in
      s.toolStatus[call.id] = .completed
      s.messages.append(.toolResult(.init(
        toolCallId: call.id, toolName: call.name,
        content: [.text(result.output)]
      )))
      return s.messages
    }
    return [.toolStatusUpdated(id: call.id, status: .completed), .messagesUpdated(msgs)]
  }

  func toolDidFail(_ call: ToolCall, error: any Error, state: CheckpointState) async throws -> [CheckpointAction] {
    let errorText: String = if let recovery = error as? CheckpointRecoveryError {
      "Tool interrupted. Last output:\n\(recovery.partialOutput)"
    } else {
      "error: \(error)"
    }
    let msgs = store.withLock { s -> [Message] in
      s.toolStatus[call.id] = .errored
      s.messages.append(.toolResult(.init(
        toolCallId: call.id, toolName: call.name,
        content: [.text(errorText)], isError: true
      )))
      return s.messages
    }
    return [.toolStatusUpdated(id: call.id, status: .errored), .messagesUpdated(msgs)]
  }

  func shouldCompact(state: CheckpointState) -> Bool { false }
  func performCompaction(state: CheckpointState) async throws -> [CheckpointAction] { [] }

  func unresolvedToolCalls(in state: CheckpointState) -> [(id: String, call: ToolCall)] {
    state.toolStatus.compactMap { id, status in
      guard status == .started else { return nil }
      for msg in state.messages {
        guard let assistant = msg.assistant else { continue }
        for block in assistant.content {
          if case let .toolCall(call) = block, call.id == id {
            return (id: id, call: call)
          }
        }
      }
      return nil
    }
  }

  func hasWork(state: CheckpointState) -> Bool { state.hasWork }
}

struct CheckpointRecoveryError: Error, Sendable {
  var partialOutput: String
}

// MARK: - Tests

@Suite("Example 2: Tool Checkpointing")
struct CheckpointTests {
  @Test func checkpointEmitsDuringExecution() async throws {
    let toolCall = ToolCall(id: "bash-1", name: "bash", arguments: .object([:]))
    let behavior = CheckpointBehavior(
      mockResponses: [
        AssistantMessage(provider: .openai, model: "mock", content: [.toolCall(toolCall)], stopReason: .toolUse),
        AssistantMessage(provider: .openai, model: "mock", content: [.text("done")]),
      ],
      bashChunks: ["line1\n", "line2\n", "line3\n"]
    )

    let loop = AgentLoop(behavior: behavior)
    let observation = await loop.observe()
    let loopTask = Task { try await loop.start() }

    try await loop.send(.enqueue("run bash"))

    var checkpoints: [String] = []
    for await event in observation.events {
      if case let .committed(action) = event {
        if case let .toolCheckpointed(_, output) = action {
          checkpoints.append(output)
        }
        if case let .messagesUpdated(msgs) = action,
           msgs.last?.assistant?.content.first == .text("done")
        {
          break
        }
      }
    }

    loopTask.cancel()

    #expect(checkpoints.count == 3)
    #expect(checkpoints[0] == "line1\n")
    #expect(checkpoints[1] == "line1\nline2\n")
    #expect(checkpoints[2] == "line1\nline2\nline3\n")
  }

  @Test func unresolvedToolCall_errorRecovery() async throws {
    let toolCall = ToolCall(id: "bash-2", name: "bash", arguments: .object([:]))

    // Phase 1: tool crashes after 2 chunks.
    let behavior = CheckpointBehavior(
      mockResponses: [
        AssistantMessage(provider: .openai, model: "mock", content: [.toolCall(toolCall)], stopReason: .toolUse),
        // After error recovery, inference runs again:
        AssistantMessage(provider: .openai, model: "mock", content: [.text("recovered")]),
      ],
      bashChunks: ["line1\n", "line2\n", "line3\n"],
      crashAfterChunks: 2,
      recoveryMode: .errorWithCheckpoint
    )

    let loop = AgentLoop(behavior: behavior)
    let loopTask = Task { try await loop.start() }
    try await loop.send(.enqueue("run bash"))

    try await Task.sleep(nanoseconds: 1_000_000_000)

    let state = await loop.state
    loopTask.cancel()

    // Checkpoint should have captured 2 chunks.
    #expect(state.toolCheckpoints["bash-2"] == "line1\nline2\n")
    #expect(state.toolStatus["bash-2"] == .errored)

    let lastAssistant = state.messages.last { $0.assistant != nil }
    #expect(lastAssistant?.assistant?.content.first == .text("recovered"))
  }

  @Test func unresolvedToolCall_resumeOnRestart() async throws {
    let toolCall = ToolCall(id: "bash-3", name: "bash", arguments: .object([:]))

    // Simulate state after crash: tool in .started, checkpoint exists.
    let seededState = CheckpointState(
      messages: [
        .user("run bash"),
        .assistant(AssistantMessage(
          provider: .openai, model: "mock",
          content: [.toolCall(toolCall)],
          stopReason: .toolUse
        )),
      ],
      toolStatus: ["bash-3": .started],
      toolCheckpoints: ["bash-3": "line1\nline2\n"],
      hasWork: true
    )

    let behavior = CheckpointBehavior(
      mockResponses: [
        // After resume, tool result triggers inference:
        AssistantMessage(provider: .openai, model: "mock", content: [.text("resumed and done")]),
      ],
      recoveryMode: .resume,
      initialState: seededState
    )

    let loop = AgentLoop(behavior: behavior)
    let loopTask = Task { try await loop.start() }

    try await Task.sleep(nanoseconds: 1_000_000_000)

    let state = await loop.state
    loopTask.cancel()

    // Tool should have completed via resume.
    #expect(state.toolStatus["bash-3"] == .completed)

    // The output should include the resumed portion.
    let toolResult = state.messages.first { $0.toolResult?.toolCallId == "bash-3" }
    let resultText = toolResult?.toolResult?.content.first
    #expect(resultText == .text("line1\nline2\nresumed-output\n"))
  }
}
