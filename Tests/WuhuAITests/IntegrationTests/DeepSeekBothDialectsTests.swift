import Foundation
@testable import WuhuAI
import Testing

// MARK: - DeepSeek Both Dialects

/// Test deepseek-v4-pro via both Chat Completions and Anthropic endpoints.
/// Same model, two different wire formats.

private let chatTestCases: [(model: String, recordingName: String, kind: String)] = [
  ("deepseek-v4-pro", "deepseek-chat-plain-text", "plain-text"),
  ("deepseek-v4-pro", "deepseek-chat-tool-loop", "tool-loop"),
  ("deepseek-v4-pro", "deepseek-chat-reasoning", "reasoning"),
]

private let anthropicTestCases: [(model: String, recordingName: String, kind: String)] = [
  ("deepseek-v4-pro", "deepseek-anthropic-plain-text", "plain-text"),
  ("deepseek-v4-pro", "deepseek-anthropic-tool-loop", "tool-loop"),
  ("deepseek-v4-pro", "deepseek-anthropic-reasoning", "reasoning"),
]

@Suite struct DeepSeekBothDialectsTests {
  // MARK: - Chat Completions

  @Test(arguments: chatTestCases)
  func deepseekChatEndpoint(
    model: String, recordingName: String, kind: String,
  ) async throws {
    try await withRecording(recordingName) { recording in
      let endpoint = makeEndpoint(providerID: "deepseek", model: model)

      switch kind {
      case "plain-text":
        try await testPlainText(endpoint: endpoint, recording: recording)
      case "tool-loop":
        try await testToolLoop(endpoint: endpoint, recording: recording)
      case "reasoning":
        try await testReasoning(endpoint: endpoint, recording: recording, isAnthropic: false)
      default:
        break
      }
    }
  }

  // MARK: - Anthropic Endpoint

  @Test(arguments: anthropicTestCases)
  func deepseekAnthropicEndpoint(
    model: String, recordingName: String, kind: String,
  ) async throws {
    try await withRecording(recordingName) { recording in
      let endpoint = makeEndpoint(providerID: "deepseek-anthropic", model: model)

      switch kind {
      case "plain-text":
        try await testPlainText(endpoint: endpoint, recording: recording)
      case "tool-loop":
        try await testToolLoop(endpoint: endpoint, recording: recording)
      case "reasoning":
        try await testReasoning(endpoint: endpoint, recording: recording, isAnthropic: true)
      default:
        break
      }
    }
  }

  // MARK: - Test Helpers

  private func testPlainText(endpoint: any ModelEndpoint, recording: RecordingContext) async throws {
    let context = Context(messages: [
      .user(UserMessage(content: [.text(TextContent(text: "Say 'hello' in exactly three words."))])),
    ])
    let (msg, _) = try await infer(endpoint: endpoint, context: context, options: RequestOptions(), recording: recording)
    #expect(!msg.content.isEmpty)
  }

  private func testToolLoop(endpoint: any ModelEndpoint, recording: RecordingContext) async throws {
    let tool = Tool(
      name: "echo",
      description: "Echoes back the input text.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "text": .object([
            "type": .string("string"),
            "description": .string("Text to echo"),
          ]),
        ]),
        "required": .array([.string("text")]),
      ]),
    )

    let context = Context(
      messages: [
        .user(UserMessage(content: [.text(TextContent(text: "Use the echo tool to echo 'testing'."))])),
      ],
      tools: [tool],
    )
    let (msg1, _) = try await infer(endpoint: endpoint, context: context, options: RequestOptions(), recording: recording)
    #expect(!msg1.content.isEmpty, "Tool call response should not be empty")

    let toolCalls = msg1.content.compactMap { block -> ToolCall? in
      if case let .toolCall(tc) = block { return tc }
      return nil
    }
    #expect(!toolCalls.isEmpty)
  }

  private func testReasoning(
    endpoint: any ModelEndpoint,
    recording: RecordingContext,
    isAnthropic: Bool,
  ) async throws {
    let context = Context(messages: [
      .user(UserMessage(content: [.text(TextContent(text: "Think step by step: what is 25 × 4?"))])),
    ])
    let (msg, _) = try await infer(
      endpoint: endpoint,
      context: context,
      options: RequestOptions(reasoning: .effort("high")),
      recording: recording,
    )

    let reasoningBlocks = msg.content.compactMap { block -> ReasoningContent? in
      if case let .reasoning(r) = block { return r }
      return nil
    }
    #expect(!reasoningBlocks.isEmpty, "Expected reasoning blocks for deepseek with effort high")
    #expect(!msg.content.isEmpty, "Reasoning response should not be empty")

    if isAnthropic {
      for block in reasoningBlocks {
        if case .encrypted = block { } else {
          #expect(Bool(false), "DeepSeek Anthropic reasoning should be encrypted")
        }
      }
    } else {
      for block in reasoningBlocks {
        if case .unencrypted = block { } else {
          #expect(Bool(false), "DeepSeek Chat reasoning should be unencrypted")
        }
      }
    }
  }
}
