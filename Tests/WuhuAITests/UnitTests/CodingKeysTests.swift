import Foundation
@testable import WuhuAI
import JSONValue
import Testing

// MARK: - CodingKeys Tests

@Suite struct CodingKeysTests {
  // MARK: ContentBlock

  @Test func contentBlockTextRoundTrips() throws {
    let block = ContentBlock.text(TextContent(text: "hello"))
    let data = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)
    #expect(decoded == block)
  }

  @Test func contentBlockReasoningRoundTrips() throws {
    let block = ContentBlock.reasoning(.encrypted(EncryptedReasoningContent(
      providerID: "anthropic",
      model: "claude",
      summary: "thinking...",
      opaque: "sig_abc",
    )))
    let data = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)
    #expect(decoded == block)
  }

  @Test func contentBlockRedactedReasoningRoundTrips() throws {
    let block = ContentBlock.reasoning(.encrypted(EncryptedReasoningContent(
      providerID: "anthropic",
      model: "claude",
      summary: nil,
      opaque: "redacted_data",
      redacted: true,
    )))
    let data = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)
    #expect(decoded == block)
    if case let .reasoning(content) = decoded, case let .encrypted(enc) = content {
      #expect(enc.redacted == true)
      #expect(enc.summary == nil)
      #expect(enc.opaque == "redacted_data")
    } else {
      #expect(Bool(false), "Expected encrypted reasoning with redacted flag")
    }
  }

  @Test func contentBlockUnencryptedReasoningRoundTrips() throws {
    let block = ContentBlock.reasoning(.unencrypted("thinking..."))
    let data = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)
    #expect(decoded == block)
  }

  @Test func contentBlockToolCallRoundTrips() throws {
    let block = ContentBlock.toolCall(ToolCall(
      id: "call_123",
      name: "search",
      arguments: .object(["query": .string("hello")]),
    ))
    let data = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)
    #expect(decoded == block)
  }

  @Test func contentBlockMediaRoundTrips() throws {
    let block = ContentBlock.media(MediaContent(
      url: URL(string: "https://example.com/img.png")!,
      mimeType: "image/png",
    ))
    let data = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)
    #expect(decoded == block)
  }

  @Test func contentBlockUsesSnakeCaseKeys() throws {
    let block = ContentBlock.reasoning(.encrypted(EncryptedReasoningContent(
      providerID: "anthropic",
      model: "claude",
      summary: "think",
      opaque: "sig",
      redacted: false,
    )))
    let data = try JSONEncoder().encode(block)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let reasoning = json["reasoning"] as! [String: Any]
    #expect(reasoning["provider_id"] as? String == "anthropic")
    #expect(reasoning["model"] as? String == "claude")
    #expect(reasoning["summary"] as? String == "think")
    #expect(reasoning["opaque"] as? String == "sig")
    #expect(reasoning["redacted"] as? Bool == false)
  }

  // MARK: Message

  @Test func userMessageRoundTrips() throws {
    let msg = Message.user(UserMessage(
      content: [.text(TextContent(text: "hi"))],
    ))
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(Message.self, from: data)
    #expect(decoded == msg)
  }

  @Test func assistantMessageRoundTrips() throws {
    let msg = Message.assistant(AssistantMessage(
      content: [.text(TextContent(text: "hello"))],
      phase: .finalAnswer,
    ))
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(Message.self, from: data)
    #expect(decoded == msg)
  }

  @Test func toolResultMessageRoundTrips() throws {
    let msg = Message.toolResult(ToolResultMessage(
      toolCallId: "call_abc",
      content: [.text(TextContent(text: "result"))],
      isError: false,
    ))
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(Message.self, from: data)
    #expect(decoded == msg)
  }

  @Test func assistantMessageUsesSnakeCaseKeys() throws {
    let msg = AssistantMessage(
      content: [.text(TextContent(text: "hello"))],
      phase: .commentary,
    )
    let data = try JSONEncoder().encode(msg)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["phase"] as? String == "commentary")
    let content = json["content"] as! [[String: Any]]
    #expect((content[0]["text"] as? [String: Any])?["text"] as? String == "hello")
  }

  // MARK: JSONValue

  @Test func jsonValueNullRoundTrips() throws {
    let value = JSONValue.null
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded == value)
  }

  @Test func jsonValueBoolRoundTrips() throws {
    let value = JSONValue.bool(true)
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded == value)
  }

  @Test func jsonValueNumberRoundTrips() throws {
    let value = JSONValue.number(42.5)
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded == value)
  }

  @Test func jsonValueStringRoundTrips() throws {
    let value = JSONValue.string("hello")
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded == value)
  }

  @Test func jsonValueArrayRoundTrips() throws {
    let value = JSONValue.array([.string("a"), .number(1)])
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded == value)
  }

  @Test func jsonValueObjectRoundTrips() throws {
    let value = JSONValue.object(["key": .string("value")])
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded == value)
  }

  // MARK: StopReason

  @Test func stopReasonEncodesAsSnakeCase() throws {
    let data = try JSONEncoder().encode(StopReason.maxTokens)
    let str = String(data: data, encoding: .utf8)!
    #expect(str.contains("max_tokens"))
  }

  // MARK: AssistantMessagePhase

  @Test func phaseEncodesAsSnakeCase() throws {
    let data = try JSONEncoder().encode(AssistantMessagePhase.finalAnswer)
    let str = String(data: data, encoding: .utf8)!
    #expect(str.contains("final_answer"))
  }
}
