import Foundation
@testable import WuhuAI
import Testing

// MARK: - Anthropic Encoding Tests

@Suite struct AnthropicRequestBuilderTests {
  @Test func buildsBasicAnthropicRequest() {
    let context = Context(
      systemPrompt: "You are helpful.",
      messages: [
        .user(UserMessage(content: [.text(TextContent(text: "Hello"))])),
      ],
    )

    let (url, headers, body) = buildAnthropicRequest(
      model: "claude-sonnet-4-6",
      baseURL: URL(string: "https://api.anthropic.com/v1")!,
      context: context,
      options: RequestOptions(),
    )

    #expect(url.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(headers["content-type"] == "application/json")
    #expect(headers["accept"] == "text/event-stream")
    #expect(headers["anthropic-version"] == "2023-06-01")
    #expect(body["model"] == .string("claude-sonnet-4-6"))
    #expect(body["stream"] == .bool(true))
    #expect(body["max_tokens"] == .number(16384))

    #expect(body["system"] == .string("You are helpful."))

    let messages = body["messages"]?.array ?? []
    #expect(messages.count == 1)
    let userMsg = messages[0].object ?? [:]
    #expect(userMsg["role"] == .string("user"))
  }

  @Test func buildsRequestWithTemperature() {
    let context = Context(messages: [.user(.init(content: [.text(.init(text: "Hi"))]))])
    let options = RequestOptions(temperature: 0.7)

    let (_, _, body) = buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: options,
    )

    #expect(body["temperature"] == .number(0.7))
  }

  @Test func buildsRequestWithMaxTokens() {
    let context = Context(messages: [.user(.init(content: [.text(.init(text: "Hi"))]))])
    let options = RequestOptions(maxTokens: 500)

    let (_, _, body) = buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: options,
    )

    #expect(body["max_tokens"] == .number(500))
  }

  @Test func buildsRequestWithTools() {
    let context = Context(
      messages: [.user(.init(content: [.text(.init(text: "Hi"))]))],
      tools: [Tool(
        name: "search",
        description: "Search",
        parameters: .object(["type": .string("object")]),
      )],
    )

    let (_, _, body) = buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
    )

    let tools = body["tools"]?.array ?? []
    #expect(tools.count == 1)
    let tool = tools[0].object ?? [:]
    #expect(tool["name"] == .string("search"))
    #expect(tool["input_schema"] != nil)
  }

  @Test func buildsRequestWithAssistantBlocks() {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "anthropic",
            model: "claude",
            summary: "Let me think...",
            opaque: "sig_abc",
          ))),
          .text(TextContent(text: "Here is the answer")),
        ],
      )),
    ])

    let (_, _, body) = buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
    )

    let messages = body["messages"]?.array ?? []
    let assistantMsg = messages[0].object ?? [:]
    #expect(assistantMsg["role"] == .string("assistant"))

    let content = assistantMsg["content"]?.array ?? []
    #expect(content.count == 2) // thinking + text

    let thinkingBlock = content[0].object ?? [:]
    #expect(thinkingBlock["type"] == .string("thinking"))
    #expect(thinkingBlock["thinking"] == .string("Let me think..."))
    #expect(thinkingBlock["signature"] == .string("sig_abc"))

    let textBlock = content[1].object ?? [:]
    #expect(textBlock["type"] == .string("text"))
    #expect(textBlock["text"] == .string("Here is the answer"))
  }

  @Test func buildsRequestWithRedactedThinking() {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "anthropic",
            model: "claude",
            summary: nil,
            opaque: "redacted_data",
            redacted: true,
          ))),
        ],
      )),
    ])

    let (_, _, body) = buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
    )

    let messages = body["messages"]?.array ?? []
    let content = messages[0].object?["content"]?.array ?? []
    let block = content[0].object ?? [:]
    #expect(block["type"] == .string("redacted_thinking"))
    #expect(block["data"] == .string("redacted_data"))
  }

  @Test func buildsRequestWithToolCalls() {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .toolCall(ToolCall(
            id: "toolu_001",
            name: "search",
            arguments: .object(["query": .string("test")]),
          )),
        ],
      )),
    ])

    let (_, _, body) = buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
    )

    let messages = body["messages"]?.array ?? []
    let content = messages[0].object?["content"]?.array ?? []
    let block = content[0].object ?? [:]
    #expect(block["type"] == .string("tool_use"))
    #expect(block["id"] == .string("toolu_001"))
    #expect(block["name"] == .string("search"))
  }

  @Test func groupsConsecutiveToolResults() {
    let context = Context(messages: [
      .toolResult(ToolResultMessage(
        toolCallId: "toolu_001",
        content: [.text(TextContent(text: "result1"))],
      )),
      .toolResult(ToolResultMessage(
        toolCallId: "toolu_002",
        content: [.text(TextContent(text: "result2"))],
      )),
    ])

    let (_, _, body) = buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
    )

    let messages = body["messages"]?.array ?? []
    #expect(messages.count == 1) // grouped into one user message
    let content = messages[0].object?["content"]?.array ?? []
    #expect(content.count == 2) // two tool_results
  }

  @Test func skipsVacuousReasoningBlock() {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "anthropic",
            model: "claude",
            summary: "",
            opaque: "",
          ))),
          .text(TextContent(text: "answer")),
        ],
      )),
    ])

    let (_, _, body) = buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
    )

    let messages = body["messages"]?.array ?? []
    let content = messages[0].object?["content"]?.array ?? []
    // Vacuous block should be skipped, leaving only the text block
    #expect(content.count == 1)
    #expect(content[0].object?["type"] == .string("text"))
  }

  @Test func redactedFlagDisambiguatesRedactedFromNoSummaryThinking() {
    // summary:nil + redacted:false + non-empty opaque → thinking block (not redacted_thinking)
    let notRedacted = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "anthropic",
            model: "claude",
            summary: nil,
            opaque: "sig_abc",
            redacted: false,
          ))),
        ],
      )),
    ])

    let (_, _, body1) = buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: notRedacted,
      options: RequestOptions(),
    )

    let block1 = (body1["messages"]?.array ?? [])[0]
      .object?["content"]?.array?[0].object ?? [:]
    #expect(block1["type"] == .string("thinking"))
    #expect(block1["signature"] == .string("sig_abc"))

    // summary:nil + redacted:true + non-empty opaque → redacted_thinking block
    let redacted = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "anthropic",
            model: "claude",
            summary: nil,
            opaque: "redacted_blob",
            redacted: true,
          ))),
        ],
      )),
    ])

    let (_, _, body2) = buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: redacted,
      options: RequestOptions(),
    )

    let block2 = (body2["messages"]?.array ?? [])[0]
      .object?["content"]?.array?[0].object ?? [:]
    #expect(block2["type"] == .string("redacted_thinking"))
    #expect(block2["data"] == .string("redacted_blob"))
  }
}
