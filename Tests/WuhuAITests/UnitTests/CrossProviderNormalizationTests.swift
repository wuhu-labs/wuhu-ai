import Foundation
@testable import WuhuAI
import Testing

// MARK: - Normalization Tests

@Suite struct CrossProviderNormalizationTests {
  // MARK: Tool Call ID Normalization

  @Test func normalizesCompoundToolCallId() {
    let result = normalizeToolCallID("call_abc123|item_xyz789", for: .anthropic)
    #expect(result == "call_abc123")
  }

  @Test func normalizesSimpleToolCallId() {
    let result = normalizeToolCallID("call_abc123", for: .anthropic)
    #expect(result == "call_abc123")
  }

  @Test func truncatesAnthropicToolCallIdTo64() {
    let long = String(repeating: "a", count: 100)
    let result = normalizeToolCallID(long, for: .anthropic)
    #expect(result.count == 64)
  }

  @Test func truncatesChatCompletionsToolCallIdTo40() {
    let long = String(repeating: "b", count: 100)
    let result = normalizeToolCallID(long, for: .chatCompletions)
    #expect(result.count == 40)
  }

  @Test func sanitizesToolCallIdChars() {
    let result = normalizeToolCallID("call+abc/123=xyz", for: .anthropic)
    #expect(!result.contains("+"))
    #expect(!result.contains("/"))
    #expect(!result.contains("="))
  }

  @Test func preservesAlphanumericToolCallId() {
    let result = normalizeToolCallID("call_ABC-123", for: .anthropic)
    #expect(result == "call_ABC-123")
  }

  // MARK: Tool Call ID Remapping in Messages

  @Test func remapsToolCallIdsAcrossMessages() {
    var messages: [Message] = [
      .assistant(AssistantMessage(
        content: [.toolCall(ToolCall(
          id: "call_abc|item_def",
          name: "search",
          arguments: .object([:]),
        ))],
      )),
      .toolResult(ToolResultMessage(
        toolCallId: "call_abc|item_def",
        content: [.text(TextContent(text: "result"))],
      )),
    ]

    normalizeToolCallIDs(in: &messages, for: .anthropic)

    // Tool call ID should be normalized
    if case let .assistant(msg) = messages[0],
       case let .toolCall(tc) = msg.content[0]
    {
      #expect(tc.id == "call_abc")
    } else {
      Issue.record("Expected tool call")
    }

    // Tool result should reference the normalized ID
    if case let .toolResult(msg) = messages[1] {
      #expect(msg.toolCallId == "call_abc")
    }
  }

  // MARK: Reasoning Normalization

  @Test func convertsReasoningToPlainTextCrossProvider() {
    var msg = AssistantMessage(
      content: [
        .reasoning(.encrypted(EncryptedReasoningContent(
          providerID: "anthropic",
          model: "claude",
          summary: "Let me think carefully",
          opaque: "sig_abc",
        ))),
        .text(TextContent(text: "answer")),
      ],
    )

    normalizeReasoningForCrossProvider(in: &msg)

    #expect(msg.content.count == 2)
    // First block should be plain text with the reasoning summary
    if case let .text(t) = msg.content[0] {
      #expect(t.text == "Let me think carefully")
    } else {
      Issue.record("Expected text block")
    }
    // Second block unchanged
    if case let .text(t) = msg.content[1] {
      #expect(t.text == "answer")
    }
  }

  @Test func dropsRedactedWithoutTextCrossProvider() {
    var msg = AssistantMessage(
      content: [
        .reasoning(.encrypted(EncryptedReasoningContent(
          providerID: "anthropic",
          model: "claude",
          summary: nil,
          opaque: "redacted_blob",
          redacted: true,
        ))),
        .text(TextContent(text: "answer")),
      ],
    )

    normalizeReasoningForCrossProvider(in: &msg)

    #expect(msg.content.count == 1)
    if case let .text(t) = msg.content[0] {
      #expect(t.text == "answer")
    }
  }

  // MARK: Full transformMessages

  private func makeTestEndpoint(providerID: String, dialect: Dialect) -> any ModelEndpoint {
    TestEndpoint(providerID: providerID, dialect: dialect)
  }

  private struct TestEndpoint: ModelEndpoint {
    let providerID: String
    let model = "test"
    let dialect: Dialect
    let baseURL = URL(string: "https://test.com")!
  }

  @Test func sameProviderPreservesReasoningOpaque() {
    var messages: [Message] = [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "openai",
            model: "gpt-5.4",
            summary: "thinking",
            opaque: "enc_blob",
          ))),
        ],
      )),
    ]

    let endpoint = makeTestEndpoint(providerID: "openai", dialect: .responses)
    transformMessages(&messages, from: "openai", to: endpoint)

    // Same provider — opaque should be preserved
    if case let .assistant(msg) = messages[0],
       case let .reasoning(reasoning) = msg.content[0],
       case let .encrypted(enc) = reasoning
    {
      #expect(enc.opaque == "enc_blob")
    } else {
      Issue.record("Expected reasoning block preserved")
    }
  }

  @Test func differentProviderConvertsReasoningToPlainText() {
    var messages: [Message] = [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "anthropic",
            model: "claude",
            summary: "thinking",
            opaque: "sig_abc",
          ))),
        ],
      )),
    ]

    let endpoint = makeTestEndpoint(providerID: "openai", dialect: .responses)
    transformMessages(&messages, from: "anthropic", to: endpoint)

    // Different provider — reasoning converted to plain text
    if case let .assistant(msg) = messages[0],
       case let .text(t) = msg.content[0]
    {
      #expect(t.text == "thinking")
    } else {
      Issue.record("Expected plain text block")
    }
  }

  @Test func differentProviderNormalizesToolCallIds() {
    var messages: [Message] = [
      .assistant(AssistantMessage(
        content: [.toolCall(ToolCall(
          id: "call_1|item_long_id_with_special_chars+/=",
          name: "search",
          arguments: .object([:]),
        ))],
      )),
      .toolResult(ToolResultMessage(
        toolCallId: "call_1|item_long_id_with_special_chars+/=",
        content: [.text(TextContent(text: "result"))],
      )),
    ]

    let endpoint = makeTestEndpoint(providerID: "anthropic", dialect: .anthropic)
    transformMessages(&messages, from: "openai", to: endpoint)

    // Tool call ID should be normalized and sanitized
    if case let .assistant(msg) = messages[0],
       case let .toolCall(tc) = msg.content[0]
    {
      #expect(!tc.id.contains("|"))
      #expect(!tc.id.contains("+"))
    }

    // Tool result should match
    if case let .assistant(msg) = messages[0],
       case let .toolCall(tc) = msg.content[0],
       case let .toolResult(tr) = messages[1]
    {
      #expect(tr.toolCallId == tc.id)
    }
  }

  @Test func transformedContextReturnsNewContext() {
    let context = Context(
      systemPrompt: "System",
      messages: [
        .assistant(AssistantMessage(
          content: [
            .reasoning(.encrypted(EncryptedReasoningContent(
              providerID: "anthropic",
              model: "claude",
              summary: "thinking",
              opaque: "sig",
            ))),
          ],
        )),
      ],
    )

    let endpoint = makeTestEndpoint(providerID: "openai", dialect: .responses)
    let result = transformedContext(context, from: "anthropic", to: endpoint)

    #expect(result.systemPrompt == "System")
    #expect(result.messages.count == 1)
    // Reasoning should be converted to text
    if case let .assistant(msg) = result.messages[0],
       case let .text(t) = msg.content[0]
    {
      #expect(t.text == "thinking")
    }
  }
}
