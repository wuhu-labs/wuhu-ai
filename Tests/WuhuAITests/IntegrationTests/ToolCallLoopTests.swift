import Foundation
@testable import WuhuAI
import Testing

// MARK: - Tool Call Loop

/// Test tool call loop with double_number tool.
///
/// Turn 1: "Use the double_number tool to double 21."
///   → stopReason == .stop, has toolCall with name "double_number"
/// Tool result: 42
/// Turn 2: "Now say the result in a sentence."
///   → stopReason == .stop, text contains "42"

private let toolLoopModels: [ModelEntry] = [
  ModelEntry(providerID: "anthropic", model: "claude-sonnet-4-6", recordingName: "claude-sonnet-4-6-tool-loop"),
  ModelEntry(providerID: "anthropic", model: "claude-opus-4-7", recordingName: "claude-opus-4-7-tool-loop"),
  ModelEntry(providerID: "deepseek", model: "deepseek-v4-pro", recordingName: "deepseek-v4-pro-tool-loop"),
  ModelEntry(providerID: "gemini", model: "gemini-2.5-flash", recordingName: "gemini-2.5-flash-tool-loop"),
  ModelEntry(providerID: "gemini", model: "gemini-3-flash-preview", recordingName: "gemini-3-flash-tool-loop"),
  ModelEntry(providerID: "kimi", model: "kimi-k2.6", recordingName: "kimi-k2.6-tool-loop"),
  ModelEntry(providerID: "openai", model: "gpt-5.4", recordingName: "gpt-5.4-tool-loop"),
]

/// Build the double_number tool definition.
private let doubleNumberTool = Tool(
  name: "double_number",
  description: "Doubles a number and returns the result.",
  parameters: .object([
    "type": .string("object"),
    "properties": .object([
      "number": .object([
        "type": .string("integer"),
        "description": .string("The number to double"),
      ]),
    ]),
    "required": .array([.string("number")]),
  ]),
)

@Suite struct ToolCallLoopTests {
  @Test(arguments: toolLoopModels)
  func toolCallDoubleNumber(entry: ModelEntry) async throws {
    try await withRecording(entry.recordingName) {
      let endpoint = makeEndpoint(entry)

      // Turn 1: Request tool call.
      var context = Context(
        messages: [
          .user(UserMessage(content: [.text(TextContent(text: "Use the double_number tool to double 21."))])),
        ],
        tools: [doubleNumberTool],
      )
      let msg1 = try await endpoint.infer(
        context: context,
        options: RequestOptions(),
      ).message

      let toolCalls = msg1.content.compactMap { block -> ToolCall? in
        if case let .toolCall(tc) = block { return tc }
        return nil
      }
      #expect(!toolCalls.isEmpty, "Expected at least one tool call")
      if let firstCall = toolCalls.first {
        #expect(firstCall.name == "double_number")
        #expect(firstCall.arguments != .object([:]), "Tool call arguments must not be empty")
        #expect(firstCall.arguments.object?["number"] != nil, "Expected 'number' argument")
      }

      // Provide tool result.
      context.messages.append(.assistant(msg1))
      for call in toolCalls {
        context.messages.append(.toolResult(ToolResultMessage(
          toolCallId: call.id,
          content: [.text(TextContent(text: "42"))],
        )))
      }

      // Turn 2: Follow-up.
      context.messages.append(.user(UserMessage(content: [.text(TextContent(text: "Now say the result in a sentence."))])))
      let msg2 = try await endpoint.infer(
        context: context,
        options: RequestOptions(),
      ).message

      let allText = msg2.content.compactMap { block -> String? in
        if case let .text(t) = block { return t.text }
        return nil
      }.joined()
      #expect(allText.contains("42"), "Expected response to mention '42', got: \(allText)")
    }
  }
}
