import Foundation
@testable import WuhuAI
import Testing

// MARK: - Random Number Tool Call Test

/// Test random number tool call with explicit min/max arguments.
///
/// Prompt: "Call the generate_random tool with min=0 and max=100."
///   → stopReason == .stop, has toolCall with name "generate_random"
///   → arguments contain both "min" and "max" as numbers

private let randomToolModels: [ModelEntry] = [
  ModelEntry(providerID: "deepseek", model: "deepseek-v4-pro", recordingName: "deepseek-v4-pro-random-tool"),
  ModelEntry(providerID: "anthropic", model: "claude-sonnet-4-6", recordingName: "claude-sonnet-4-6-random-tool"),
  ModelEntry(providerID: "gemini", model: "gemini-3-flash-preview", recordingName: "gemini-3-flash-random-tool"),
]

/// Build the generate_random tool definition.
private let generateRandomTool = Tool(
  name: "generate_random",
  description: "Generate a random integer between min and max inclusive. Call this tool with explicit min and max values.",
  parameters: .object([
    "type": .string("object"),
    "properties": .object([
      "min": .object([
        "type": .string("integer"),
        "description": .string("The minimum value (inclusive). Required."),
      ]),
      "max": .object([
        "type": .string("integer"),
        "description": .string("The maximum value (inclusive). Required."),
      ]),
    ]),
    "required": .array([.string("min"), .string("max")]),
  ]),
)

@Suite struct RandomToolTests {
  @Test(arguments: randomToolModels)
  func toolCallWithArguments(entry: ModelEntry) async throws {
    try await withRecording(entry.recordingName) {
      let endpoint = makeEndpoint(entry)

      let context = Context(
        messages: [
          .user(UserMessage(content: [.text(TextContent(
            text: "You MUST call the generate_random tool now. Pass min=0 and max=100. Do not say anything else — just call the tool.",
          ))])),
        ],
        tools: [generateRandomTool],
      )

      let msg = try await endpoint.infer(
        context: context,
        options: RequestOptions(),
      ).message

      let toolCalls = msg.content.compactMap { block -> ToolCall? in
        if case let .toolCall(tc) = block { return tc }
        return nil
      }
      #expect(!toolCalls.isEmpty, "Expected at least one tool call")
      if let call = toolCalls.first {
        #expect(call.name == "generate_random", "Expected generate_random tool, got \(call.name)")
        #expect(call.arguments != .object([:]), "Tool call arguments must not be empty")
        if case let .object(args) = call.arguments {
          #expect(args["min"] != nil, "Missing 'min' argument")
          #expect(args["max"] != nil, "Missing 'max' argument")
          if case let .number(minVal) = args["min"] {
            #expect(minVal >= 0, "min should be >= 0, got \(minVal)")
          }
          if case let .number(maxVal) = args["max"] {
            #expect(maxVal <= 100, "max should be <= 100, got \(maxVal)")
          }
        }
      }
    }
  }
}
