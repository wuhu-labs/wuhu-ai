import Foundation
@testable import WuhuAI
import Testing

// MARK: - Responses Stream Parser Tests

@Suite struct ResponsesStreamParserTests {
  private func sse(_ events: [SSEEvent]) -> AsyncThrowingStream<SSEEvent, Error> {
    AsyncThrowingStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }

  private func jsonEvent(_ dict: [String: Any]) -> SSEEvent {
    let data = try! JSONSerialization.data(withJSONObject: dict, options: [])
    return SSEEvent(data: String(data: data, encoding: .utf8)!)
  }

  @Test func parsesSimpleTextStream() async throws {
    let events = [
      jsonEvent(["type": "response.output_item.added", "item": [
        "type": "message", "id": "msg_1", "role": "assistant",
        "content": [],
      ]]),
      jsonEvent(["type": "response.output_text.delta", "delta": "Hello"]),
      jsonEvent(["type": "response.output_text.delta", "delta": " world"]),
      jsonEvent(["type": "response.output_item.done", "item": [
        "type": "message", "id": "msg_1",
      ]]),
      jsonEvent(["type": "response.completed", "response": [
        "status": "completed",
        "usage": ["input_tokens": 10, "output_tokens": 5, "total_tokens": 15],
      ]]),
    ]

    let stream = parseResponsesStream(sse(events), providerID: "openai", model: "gpt-5.4")
    var results: [AssistantMessageEvent] = []
    for try await event in stream { results.append(event) }

    if case let .done(msg, metadata) = results.last {
      #expect(metadata.stopReason == .stop)
      let texts = msg.content.compactMap { block -> String? in
        if case let .text(t) = block { return t.text }
        return nil
      }.joined()
      #expect(texts == "Hello world")
      #expect(metadata.usage?.inputTokens == 10)
      #expect(metadata.usage?.outputTokens == 5)
    }
  }

  @Test func parsesFunctionCall() async throws {
    let events = [
      jsonEvent(["type": "response.output_item.added", "item": [
        "type": "function_call",
        "call_id": "call_1",
        "id": "item_1",
        "name": "search",
        "arguments": "",
      ]]),
      jsonEvent(["type": "response.function_call_arguments.delta", "delta": #"{"query":"#]),
      jsonEvent(["type": "response.function_call_arguments.delta", "delta": #""test"}"#]),
      jsonEvent(["type": "response.function_call_arguments.done", "arguments": #"{"query":"test"}"#]),
      jsonEvent(["type": "response.output_item.done", "item": [
        "type": "function_call", "call_id": "call_1", "name": "search",
        "arguments": #"{"query":"test"}"#,
      ]]),
      jsonEvent(["type": "response.completed", "response": [
        "status": "completed",
        "usage": ["input_tokens": 10, "output_tokens": 5, "total_tokens": 15],
      ]]),
    ]

    let stream = parseResponsesStream(sse(events), providerID: "openai", model: "gpt-5.4")
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
      #expect(toolCalls[0].id == "call_1|item_1")
      #expect(toolCalls[0].arguments.object?["query"] == .string("test"))
    }
  }

  @Test func parsesReasoningItem() async throws {
    let events = [
      jsonEvent(["type": "response.output_item.added", "item": [
        "type": "reasoning",
        "id": "rs_1",
        "encrypted_content": "enc_blob",
        "summary": [["type": "summary_text", "text": "Let me think"]],
      ]]),
      jsonEvent(["type": "response.output_item.done", "item": [
        "type": "reasoning", "id": "rs_1",
        "encrypted_content": "enc_blob",
        "summary": [["type": "summary_text", "text": "Let me think deeply"]],
      ]]),
      jsonEvent(["type": "response.completed", "response": [
        "status": "completed",
        "usage": ["input_tokens": 10, "output_tokens": 5, "total_tokens": 15],
      ]]),
    ]

    let stream = parseResponsesStream(sse(events), providerID: "openai", model: "gpt-5.4")
    var results: [AssistantMessageEvent] = []
    for try await event in stream { results.append(event) }

    if case let .done(msg, _) = results.last {
      let reasonings = msg.content.compactMap { block -> ReasoningContent? in
        if case let .reasoning(r) = block { return r }
        return nil
      }
      #expect(reasonings.count == 1)
      if case let .encrypted(enc) = reasonings[0] {
        #expect(enc.summary == "Let me think deeply")
        #expect(enc.opaque == "enc_blob")
        #expect(enc.id == "rs_1")
        #expect(enc.providerID == "openai")
      } else {
        #expect(Bool(false), "Expected encrypted reasoning")
      }
    }
  }

  @Test func parsesPhaseMetadata() async throws {
    let events = [
      jsonEvent(["type": "response.output_item.added", "item": [
        "type": "message", "id": "msg_1", "phase": "commentary",
        "content": [],
      ]]),
      jsonEvent(["type": "response.output_text.delta", "delta": "thinking..."]),
      jsonEvent(["type": "response.output_item.done", "item": [
        "type": "message", "id": "msg_1", "phase": "commentary",
      ]]),
      jsonEvent(["type": "response.completed", "response": [
        "status": "completed",
        "usage": ["input_tokens": 10, "output_tokens": 5, "total_tokens": 15],
      ]]),
    ]

    let stream = parseResponsesStream(sse(events), providerID: "openai", model: "gpt-5.4")
    var results: [AssistantMessageEvent] = []
    for try await event in stream { results.append(event) }

    if case let .done(msg, _) = results.last {
      #expect(msg.phase == .commentary)
    }
  }

  @Test func handlesErrorResponse() async throws {
    let events = [
      jsonEvent(["type": "response.failed", "response": ["status": "failed"]]),
    ]

    let stream = parseResponsesStream(sse(events), providerID: "openai", model: "gpt-5.4")
    do {
      for try await _ in stream {}
      Issue.record("Expected stream to throw")
    } catch {
      // Expected — response.failed now throws
    }
  }
}
