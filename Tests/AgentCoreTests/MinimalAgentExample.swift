import AgentCore
import Foundation
import PiAI
import Testing

// MARK: - Example 1: Minimal Agent

/// The simplest possible AgentBehavior. In-memory state, no persistence,
/// pure function tools. Proves the loop works with zero infrastructure.
///
/// State is just `[Message]`. Tools return instantly. "Persistence" is
/// a ``TestStore`` acting as a fake store — `loadState()` reads from it,
/// actions write to it.
///
/// This is the baseline: if you can implement AgentBehavior with arrays
/// and closures, the protocol is right.

// MARK: State

struct MinimalState: Sendable, Equatable {
  var messages: [Message] = []
  var hasWork: Bool = false
}

// MARK: Actions

enum MinimalAction: Sendable, Equatable {
  case messagesUpdated([Message])
  case workFlagUpdated(Bool)
}

enum MinimalStreamAction: Sendable {
  case textDelta(String)
}

enum MinimalExternalAction: Sendable {
  case enqueue(String)
}

// MARK: Tool Result

struct MinimalToolResult: Sendable, Hashable {
  var text: String
}

// MARK: Behavior

final class MinimalBehavior: AgentBehavior, Sendable {
  let store = TestStore(MinimalState())
  let responses: TestStore<[AssistantMessage]>
  private let callIndex = TestStore(0)

  init(mockResponses: [AssistantMessage] = []) {
    responses = TestStore(mockResponses)
  }

  static var emptyState: MinimalState { .init() }

  func loadState() async throws -> MinimalState { await store.value }

  func apply(_ action: MinimalAction, to state: inout MinimalState) {
    switch action {
    case let .messagesUpdated(msgs): state.messages = msgs
    case let .workFlagUpdated(flag): state.hasWork = flag
    }
  }

  func handle(_ action: MinimalExternalAction, state: MinimalState) async throws -> [MinimalAction] {
    switch action {
    case let .enqueue(text):
      let msgs = await store.withLock { s -> [Message] in
        s.messages.append(.user(text))
        s.hasWork = true
        return s.messages
      }
      return [.messagesUpdated(msgs), .workFlagUpdated(true)]
    }
  }

  func drainInterruptItems(state: MinimalState) async throws -> [MinimalAction] { [] }

  func drainTurnItems(state: MinimalState) async throws -> [MinimalAction] {
    guard state.hasWork else { return [] }
    await store.withLock { $0.hasWork = false }
    return [.workFlagUpdated(false)]
  }

  func buildContext(state: MinimalState) -> Context {
    Context(systemPrompt: "You are a test.", messages: state.messages, tools: nil)
  }

  func infer(context: Context, stream: AgentStreamSink<MinimalStreamAction>) async throws -> AssistantMessage {
    let idx = await callIndex.withLock { i -> Int in let v = i; i += 1; return v }
    let all = await responses.value
    guard idx < all.count else {
      throw AgentLoopError.inferenceProducedNoResult
    }
    let msg = all[idx]
    for block in msg.content {
      if case let .text(t) = block {
        stream.yield(.textDelta(t.text))
      }
    }
    return msg
  }

  func persistAssistantEntry(_ message: AssistantMessage, state: MinimalState) async throws -> [MinimalAction] {
    let msgs = await store.withLock { s -> [Message] in
      s.messages.append(.assistant(message))
      return s.messages
    }
    return [.messagesUpdated(msgs)]
  }

  func toolWillExecute(_ call: ToolCall, state: MinimalState) async throws -> [MinimalAction] { [] }

  func executeToolCall(
    _ call: ToolCall,
    sink: ToolActionSink<MinimalAction>,
    resolution: ToolCallResolution
  ) async throws -> MinimalToolResult {
    MinimalToolResult(text: "echo: \(call.name)")
  }

  func appendText(_ text: String, to result: MinimalToolResult) -> MinimalToolResult {
    MinimalToolResult(text: result.text + text)
  }

  func toolDidExecute(_ call: ToolCall, result: MinimalToolResult, state: MinimalState) async throws -> [MinimalAction] {
    let msgs = await store.withLock { s -> [Message] in
      s.messages.append(.toolResult(.init(
        toolCallId: call.id,
        toolName: call.name,
        content: [.text(result.text)]
      )))
      return s.messages
    }
    return [.messagesUpdated(msgs)]
  }

  func toolDidFail(_ call: ToolCall, error: any Error, state: MinimalState) async throws -> [MinimalAction] {
    let msgs = await store.withLock { s -> [Message] in
      s.messages.append(.toolResult(.init(
        toolCallId: call.id,
        toolName: call.name,
        content: [.text("error: \(error)")],
        isError: true
      )))
      return s.messages
    }
    return [.messagesUpdated(msgs)]
  }

  func shouldCompact(state: MinimalState) -> Bool { false }
  func performCompaction(state: MinimalState) async throws -> [MinimalAction] { [] }
  func unresolvedToolCalls(in state: MinimalState) -> [(id: String, call: ToolCall)] { [] }
  func hasWork(state: MinimalState) -> Bool { state.hasWork }
}

// MARK: - Tests

@Suite("Example 1: Minimal Agent")
struct MinimalAgentTests {
  @Test func basicTextResponse() async throws {
    let behavior = MinimalBehavior(mockResponses: [
      AssistantMessage(provider: .openai, model: "mock", content: [.text("hello back")]),
    ])

    let loop = AgentLoop(behavior: behavior)
    let observation = await loop.observe()
    let loopTask = Task { try await loop.start() }

    try await loop.send(.enqueue("hello"))

    var sawAssistantEntry = false
    for await event in observation.events {
      if case let .committed(action) = event,
         case let .messagesUpdated(msgs) = action,
         msgs.last?.assistant != nil
      {
        sawAssistantEntry = true
        break
      }
    }

    loopTask.cancel()
    #expect(sawAssistantEntry)

    let finalState = await loop.state
    #expect(finalState.messages.count == 2) // user + assistant
    #expect(finalState.messages[1].assistant?.content.first == .text("hello back"))
  }

  @Test func toolCallRoundTrip() async throws {
    let toolCall = ToolCall(id: "tc1", name: "echo", arguments: .object([:]))
    let behavior = MinimalBehavior(mockResponses: [
      AssistantMessage(provider: .openai, model: "mock", content: [.toolCall(toolCall)], stopReason: .toolUse),
      AssistantMessage(provider: .openai, model: "mock", content: [.text("done")]),
    ])

    let loop = AgentLoop(behavior: behavior)
    let loopTask = Task { try await loop.start() }

    try await loop.send(.enqueue("use the tool"))

    try await Task.sleep(nanoseconds: 500_000_000)

    let finalState = await loop.state
    loopTask.cancel()

    // user + assistant(toolCall) + toolResult + assistant(done)
    let assistants = finalState.messages.filter { $0.assistant != nil }
    #expect(assistants.count == 2)

    let toolResults = finalState.messages.filter { $0.toolResult != nil }
    #expect(toolResults.count == 1)
    #expect(toolResults[0].toolResult?.content.first == .text("echo: echo"))
  }
}
