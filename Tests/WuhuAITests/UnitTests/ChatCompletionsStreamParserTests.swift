import Foundation
@testable import WuhuAI
import Testing

// MARK: - Chat Completions Stream Parser Tests

@Suite struct ChatCompletionsStreamParserTests {
  // MARK: - Helpers

  private func sse(_ events: [SSEEvent]) -> AsyncThrowingStream<SSEEvent, Error> {
    AsyncThrowingStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }

  private func chatChoiceDelta(content: String? = nil, reasoningContent: String? = nil, finishReason: String? = nil) -> String {
    var delta: [String: Any] = [:]
    if let c = content { delta["content"] = c }
    if let r = reasoningContent { delta["reasoning_content"] = r }
    var dict: [String: Any] = [
      "choices": [[
        "index": 0,
        "delta": delta,
      ]],
    ]
    if let f = finishReason {
      dict["choices"] = [[
        "index": 0,
        "delta": delta,
        "finish_reason": f,
      ]]
    }
    let data = try! JSONSerialization.data(withJSONObject: dict, options: [])
    return String(data: data, encoding: .utf8)!
  }

  // MARK: - Tests

  @Test func parsesSimpleTextStream() async throws {
    let events = [
      SSEEvent(data: chatChoiceDelta(content: "Hello")),
      SSEEvent(data: chatChoiceDelta(content: " world", finishReason: "stop")),
    ]

    let stream = parseChatCompletionsStream(sse(events), providerID: "test", model: "test-model")
    var results: [AssistantMessageEvent] = []
    for try await event in stream { results.append(event) }

    // start + textStart + textDelta + textDelta + textEnd + done
    #expect(results.count >= 3)

    if case let .done(msg, metadata) = results.last {
      #expect(metadata.stopReason == .stop)
      let texts = msg.content.compactMap { block -> String? in
        if case let .text(t) = block { return t.text }
        return nil
      }.joined()
      #expect(texts == "Hello world")
    } else {
      Issue.record("Expected done event as last event")
    }
  }

  @Test func parsesReasoningContent() async throws {
    let events = [
      SSEEvent(data: chatChoiceDelta(reasoningContent: "Let me think")),
      SSEEvent(data: chatChoiceDelta(reasoningContent: " deeply")),
      SSEEvent(data: chatChoiceDelta(content: "Answer", finishReason: "stop")),
    ]

    let stream = parseChatCompletionsStream(sse(events), providerID: "test", model: "test-model")
    var results: [AssistantMessageEvent] = []
    for try await event in stream { results.append(event) }

    if case let .done(msg, _) = results.last {
      let reasonings = msg.content.compactMap { block -> ReasoningContent? in
        if case let .reasoning(r) = block { return r }
        return nil
      }
      #expect(reasonings.count == 1)
      if case let .unencrypted(text) = reasonings[0] {
        #expect(text == "Let me think deeply")
      } else {
        #expect(Bool(false), "Expected unencrypted reasoning")
      }
    }
  }

  @Test func parsesToolCalls() async throws {
    let toolCallDelta: [String: Any] = [
      "choices": [[
        "index": 0,
        "delta": [
          "tool_calls": [[
            "index": 0,
            "id": "call_1",
            "type": "function",
            "function": [
              "name": "search",
              "arguments": #"{"query":"test"}"#,
            ],
          ]],
        ],
        "finish_reason": "tool_calls",
      ]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: toolCallDelta, options: [])
    let event = SSEEvent(data: String(data: data, encoding: .utf8)!)

    let stream = parseChatCompletionsStream(sse([event]), providerID: "test", model: "test-model")
    var results: [AssistantMessageEvent] = []
    for try await event in stream { results.append(event) }

    if case let .done(msg, metadata) = results.last {
      #expect(metadata.stopReason == .stop)
      let toolCalls = msg.content.compactMap { block -> ToolCall? in
        if case let .toolCall(tc) = block { return tc }
        return nil
      }
      #expect(toolCalls.count == 1)
      #expect(toolCalls[0].name == "search")
    }
  }

  @Test func parsesUsageInformation() async throws {
    let usageEvent: [String: Any] = [
      "choices": [[
        "index": 0,
        "delta": [:],
        "finish_reason": "stop",
      ]],
      "usage": [
        "prompt_tokens": 10,
        "completion_tokens": 5,
        "total_tokens": 15,
      ],
    ]
    let data = try! JSONSerialization.data(withJSONObject: usageEvent, options: [])
    let event = SSEEvent(data: String(data: data, encoding: .utf8)!)

    let stream = parseChatCompletionsStream(sse([event]), providerID: "test", model: "test-model")
    var results: [AssistantMessageEvent] = []
    for try await event in stream { results.append(event) }

    if case let .done(_, metadata) = results.last {
      #expect(metadata.usage?.inputTokens == 10)
      #expect(metadata.usage?.outputTokens == 5)
      #expect(metadata.usage?.totalTokens == 15)
    }
  }

  @Test func emitsStartEvent() async throws {
    let events = [SSEEvent(data: chatChoiceDelta(content: "Hi", finishReason: "stop"))]
    let stream = parseChatCompletionsStream(sse(events), providerID: "openai", model: "gpt-5")
    var results: [AssistantMessageEvent] = []
    for try await event in stream { results.append(event) }

    if case let .start(msg) = results.first {
      #expect(msg.content.isEmpty)
      #expect(msg.phase == nil)
    } else {
      Issue.record("Expected start event as first")
    }
  }

  @Test func handlesDoneMarker() async throws {
    let events = [SSEEvent(data: "[DONE]")]
    let stream = parseChatCompletionsStream(sse(events), providerID: "test", model: "m")
    var results: [AssistantMessageEvent] = []
    for try await event in stream { results.append(event) }

    if case .done = results.last {
      // OK
    } else {
      Issue.record("Expected done event")
    }
  }

  @Test func handlesErrorInStream() async throws {
    let stream = AsyncThrowingStream<SSEEvent, Error> { continuation in
      continuation.finish(throwing: NSError(domain: "test", code: 1))
    }

    let parsed = parseChatCompletionsStream(stream, providerID: "test", model: "m")
    do {
      for try await event in parsed { _ = event }
      Issue.record("Expected stream to throw")
    } catch {
      // Expected — stream throws on error, no more .error event
    }
  }
}
