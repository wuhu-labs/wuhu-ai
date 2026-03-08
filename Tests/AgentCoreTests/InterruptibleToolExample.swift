import AgentCore
import Foundation
import PiAI
import Testing

// MARK: - Example 3: Interruptible Blocking Tool

/// Demonstrates a "join" tool that blocks until an external event
/// arrives, but yields early when a steer/interrupt message comes in.
///
/// The pattern: the behavior wires an internal interrupt signal from
/// its `handle(.steer)` to the tool's execution context. The tool
/// races between "wait for result" and "wait for interrupt."
///
/// **No loop changes needed.** This is entirely at the behavior level.
/// The loop sees: tool started, tool finished (possibly early), drain
/// interrupt (steer message), infer.

// MARK: State

struct InterruptState: Sendable, Equatable {
  var messages: [Message] = []
  var hasWork: Bool = false
  var pendingSteer: String? = nil
}

// MARK: Actions

enum InterruptAction: Sendable, Equatable {
  case messagesUpdated([Message])
  case workFlagUpdated(Bool)
  case steerEnqueued(String)
  case steerDrained
}

enum InterruptExternalAction: Sendable {
  case enqueue(String)
  case steer(String)
}

struct InterruptToolResult: Sendable, Hashable {
  var text: String
}

// MARK: Interrupt Signal

/// A broadcast signal that tools can subscribe to.
/// When `fire()` is called, all waiting `wait()` calls resume.
actor InterruptSignal {
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    await withCheckedContinuation { cont in
      continuations.append(cont)
    }
  }

  func fire() {
    let pending = continuations
    continuations.removeAll()
    for cont in pending {
      cont.resume()
    }
  }
}

// MARK: Behavior

final class InterruptBehavior: AgentBehavior, Sendable {
  typealias StreamAction = String

  let store: TestStore<InterruptState>
  let responses: TestStore<[AssistantMessage]>
  private let callIndex = TestStore(0)
  let interruptSignal = InterruptSignal()
  let joinDelayNanoseconds: UInt64

  init(
    mockResponses: [AssistantMessage] = [],
    joinDelayNanoseconds: UInt64 = 5_000_000_000
  ) {
    self.store = TestStore(.init())
    self.responses = TestStore(mockResponses)
    self.joinDelayNanoseconds = joinDelayNanoseconds
  }

  static var emptyState: InterruptState { .init() }

  func loadState() async throws -> InterruptState { await store.value }

  func apply(_ action: InterruptAction, to state: inout InterruptState) {
    switch action {
    case let .messagesUpdated(msgs): state.messages = msgs
    case let .workFlagUpdated(flag): state.hasWork = flag
    case let .steerEnqueued(text): state.pendingSteer = text
    case .steerDrained: state.pendingSteer = nil
    }
  }

  func handle(_ action: InterruptExternalAction, state: InterruptState) async throws -> [InterruptAction] {
    switch action {
    case let .enqueue(text):
      let msgs = await store.withLock { s -> [Message] in
        s.messages.append(.user(text))
        s.hasWork = true
        return s.messages
      }
      return [.messagesUpdated(msgs), .workFlagUpdated(true)]

    case let .steer(text):
      await store.withLock { $0.pendingSteer = text }
      // Fire the interrupt signal so blocking tools wake up.
      await interruptSignal.fire()
      return [.steerEnqueued(text)]
    }
  }

  func drainInterruptItems(state: InterruptState) async throws -> [InterruptAction] {
    guard let steer = state.pendingSteer else { return [] }
    let msgs = await store.withLock { s -> [Message] in
      s.messages.append(.user(steer))
      s.pendingSteer = nil
      return s.messages
    }
    return [.messagesUpdated(msgs), .steerDrained]
  }

  func drainTurnItems(state: InterruptState) async throws -> [InterruptAction] {
    guard state.hasWork else { return [] }
    await store.withLock { $0.hasWork = false }
    return [.workFlagUpdated(false)]
  }

  func buildContext(state: InterruptState) -> Context {
    Context(messages: state.messages)
  }

  func infer(context: Context, stream: AgentStreamSink<String>) async throws -> AssistantMessage {
    let idx = await callIndex.withLock { i -> Int in let v = i; i += 1; return v }
    let all = await responses.value
    guard idx < all.count else { throw AgentLoopError.inferenceProducedNoResult }
    return all[idx]
  }

  func persistAssistantEntry(_ message: AssistantMessage, state: InterruptState) async throws -> [InterruptAction] {
    let msgs = await store.withLock { s -> [Message] in
      s.messages.append(.assistant(message))
      return s.messages
    }
    return [.messagesUpdated(msgs)]
  }

  func toolWillExecute(_ call: ToolCall, state: InterruptState) async throws -> [InterruptAction] { [] }

  func executeToolCall(
    _ call: ToolCall,
    sink: ToolActionSink<InterruptAction>,
    resolution: ToolCallResolution
  ) async throws -> InterruptToolResult {
    if call.name == "join" {
      return await executeJoinTool()
    }
    return InterruptToolResult(text: "unknown tool")
  }

  private func executeJoinTool() async -> InterruptToolResult {
    enum Outcome { case completed, interrupted }

    let signal = interruptSignal
    let delay = joinDelayNanoseconds

    let outcome = await withTaskGroup(of: Outcome.self) { group in
      group.addTask {
        try? await Task.sleep(nanoseconds: delay)
        return .completed
      }
      group.addTask {
        await signal.wait()
        return .interrupted
      }
      let first = await group.next()!
      group.cancelAll()
      return first
    }

    switch outcome {
    case .completed:
      return InterruptToolResult(text: "join completed normally")
    case .interrupted:
      return InterruptToolResult(text: "join interrupted — new message arrived")
    }
  }

  func appendText(_ text: String, to result: InterruptToolResult) -> InterruptToolResult {
    InterruptToolResult(text: result.text + text)
  }

  func toolDidExecute(_ call: ToolCall, result: InterruptToolResult, state: InterruptState) async throws -> [InterruptAction] {
    let msgs = await store.withLock { s -> [Message] in
      s.messages.append(.toolResult(.init(
        toolCallId: call.id, toolName: call.name,
        content: [.text(result.text)]
      )))
      return s.messages
    }
    return [.messagesUpdated(msgs)]
  }

  func toolDidFail(_ call: ToolCall, error: any Error, state: InterruptState) async throws -> [InterruptAction] {
    let msgs = await store.withLock { s -> [Message] in
      s.messages.append(.toolResult(.init(
        toolCallId: call.id, toolName: call.name,
        content: [.text("error: \(error)")], isError: true
      )))
      return s.messages
    }
    return [.messagesUpdated(msgs)]
  }

  func shouldCompact(state: InterruptState) -> Bool { false }
  func performCompaction(state: InterruptState) async throws -> [InterruptAction] { [] }
  func unresolvedToolCalls(in state: InterruptState) -> [(id: String, call: ToolCall)] { [] }
  func hasWork(state: InterruptState) -> Bool { state.hasWork }
}

// MARK: - Tests

@Suite("Example 3: Interruptible Blocking Tool")
struct InterruptibleToolTests {
  @Test func joinYieldsOnSteer() async throws {
    let joinCall = ToolCall(id: "join-1", name: "join", arguments: .object([:]))
    let behavior = InterruptBehavior(
      mockResponses: [
        AssistantMessage(provider: .openai, model: "mock", content: [.toolCall(joinCall)], stopReason: .toolUse),
        AssistantMessage(provider: .openai, model: "mock", content: [.text("got interrupted, handling steer")]),
      ],
      joinDelayNanoseconds: 60_000_000_000 // 60s — would timeout without interrupt
    )

    let loop = AgentLoop(behavior: behavior)
    let loopTask = Task { try await loop.start() }

    // Enqueue initial message → inference → join tool starts.
    try await loop.send(.enqueue("wait for results"))

    // Give the loop time to start the join tool.
    try await Task.sleep(nanoseconds: 200_000_000)

    // Send a steer — should interrupt the join.
    try await loop.send(.steer("actually, do something else"))

    // Wait for processing.
    try await Task.sleep(nanoseconds: 1_000_000_000)

    let state = await loop.state
    loopTask.cancel()

    // The join tool should have returned "interrupted."
    let toolResult = state.messages.first { $0.toolResult?.toolName == "join" }
    #expect(toolResult?.toolResult?.content.first == .text("join interrupted — new message arrived"))

    // The steer message should be in the transcript.
    let userMessages = state.messages.filter { $0.user != nil }
    #expect(userMessages.count == 2) // initial + steer
  }
}
