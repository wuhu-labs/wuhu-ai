import Foundation
@testable import WuhuAI
import Testing

// MARK: - Responses Encoding Tests

@Suite struct ResponsesRequestBuilderTests {
  @Test func buildsBasicResponsesRequest() {
    let context = Context(
      systemPrompt: "You are helpful.",
      messages: [
        .user(UserMessage(content: [.text(TextContent(text: "Hello"))])),
      ],
    )

    let (url, headers, body) = buildResponsesRequest(
      model: "gpt-5.4",
      baseURL: URL(string: "https://api.openai.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
    )

    #expect(url.absoluteString == "https://api.openai.com/v1/responses")
    #expect(headers["content-type"] == "application/json")
    #expect(headers["accept"] == "text/event-stream")
    #expect(body["model"] == .string("gpt-5.4"))
    #expect(body["stream"] == .bool(true))
    #expect(body["store"] == .bool(false))

    let input = body["input"]?.array ?? []
    #expect(input.count == 2) // system + user

    let systemItem = input[0].object ?? [:]
    #expect(systemItem["role"] == .string("system"))
    #expect(systemItem["content"] == .string("You are helpful."))

    let userItem = input[1].object ?? [:]
    #expect(userItem["role"] == .string("user"))
  }

  @Test func buildsRequestWithReasoning() {
    let context = Context(messages: [.user(.init(content: [.text(.init(text: "Hi"))]))])
    let options = RequestOptions(reasoning: .effort("high"))

    let (_, _, body) = buildResponsesRequest(
      model: "gpt-5.4",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: options,
      isCodex: false,
    )

    let reasoning = body["reasoning"]?.object ?? [:]
    #expect(reasoning["effort"] == .string("high"))
    let include = body["include"]?.array ?? []
    #expect(include.contains(.string("reasoning.encrypted_content")))
  }

  @Test func buildsRequestWithTemperatureAndMaxTokens() {
    let context = Context(messages: [.user(.init(content: [.text(.init(text: "Hi"))]))])
    let options = RequestOptions(temperature: 0.5, maxTokens: 200)

    let (_, _, body) = buildResponsesRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: options,
      isCodex: false,
    )

    #expect(body["temperature"] == .number(0.5))
    #expect(body["max_output_tokens"] == .number(200))
  }

  @Test func buildsRequestWithTools() {
    let context = Context(
      messages: [.user(.init(content: [.text(.init(text: "Hi"))]))],
      tools: [Tool(
        name: "search",
        description: "Search the web",
        parameters: .object(["type": .string("object")]),
      )],
    )

    let (_, _, body) = buildResponsesRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
    )

    let tools = body["tools"]?.array ?? []
    #expect(tools.count == 1)
    let tool = tools[0].object ?? [:]
    #expect(tool["type"] == .string("function"))
    #expect(tool["name"] == .string("search"))
  }

  @Test func buildsRequestWithAssistantHistory() {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [.text(TextContent(text: "I can help"))],
      )),
      .user(UserMessage(content: [.text(TextContent(text: "Thanks"))])),
    ])

    let (_, _, body) = buildResponsesRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
    )

    let input = body["input"]?.array ?? []
    // Find the message item
    let hasMessage = input.contains { item in
      item.object?["type"] == .string("message")
    }
    #expect(hasMessage)
  }

  @Test func buildsRequestWithToolCalls() {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .toolCall(ToolCall(
            id: "call_1",
            name: "search",
            arguments: .object(["query": .string("test")]),
          )),
        ],
      )),
      .toolResult(ToolResultMessage(
        toolCallId: "call_1",
        content: [.text(TextContent(text: "result"))],
      )),
    ])

    let (_, _, body) = buildResponsesRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
    )

    let input = body["input"]?.array ?? []
    // Should have function_call and function_call_output
    let hasFunctionCall = input.contains { $0.object?["type"] == .string("function_call") }
    let hasOutput = input.contains { $0.object?["type"] == .string("function_call_output") }
    #expect(hasFunctionCall)
    #expect(hasOutput)
  }

  @Test func buildsRequestWithReasoningHistory() {
    let context = Context(messages: [
      .assistant(AssistantMessage(
        content: [
          .reasoning(.encrypted(EncryptedReasoningContent(
            providerID: "openai",
            model: "gpt-5.4",
            summary: "thinking summary",
            opaque: "encrypted_blob",
          ))),
          .text(TextContent(text: "answer")),
        ],
      )),
    ])

    let (_, _, body) = buildResponsesRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
    )

    let input = body["input"]?.array ?? []
    let hasReasoning = input.contains { $0.object?["type"] == .string("reasoning") }
    #expect(hasReasoning)
  }

  @Test func codexModePutsSystemPromptInInstructions() {
    let context = Context(
      systemPrompt: "You are a coding assistant.",
      messages: [.user(.init(content: [.text(.init(text: "Hi"))]))],
    )

    let (_, _, body) = buildResponsesRequest(
      model: "gpt-5.4-codex",
      baseURL: URL(string: "https://chatgpt.com/backend-api")!,
      context: context,
      options: RequestOptions(),
      isCodex: true,
    )

    #expect(body["instructions"] == .string("You are a coding assistant."))

    // In codex mode, system prompt should NOT be in input
    let input = body["input"]?.array ?? []
    let hasSystem = input.contains { $0.object?["role"] == .string("system") }
    #expect(!hasSystem)
  }

  @Test func nonCodexModeDoesNotPutInstructions() {
    let context = Context(
      systemPrompt: "You are helpful.",
      messages: [.user(.init(content: [.text(.init(text: "Hi"))]))],
    )

    let (_, _, body) = buildResponsesRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: context,
      options: RequestOptions(),
      isCodex: false,
    )

    #expect(body["instructions"] == nil)
  }

  @Test func toolCallIdSplitting() {
    let (callID, itemID) = splitToolCallID("call_123|item_456")
    #expect(callID == "call_123")
    #expect(itemID == "item_456")
  }

  @Test func toolCallIdSplittingWithoutItem() {
    let (callID, itemID) = splitToolCallID("call_123")
    #expect(callID == "call_123")
    #expect(itemID == nil)
  }
}
