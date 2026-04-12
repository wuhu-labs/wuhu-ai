import AI
import AICore
import Dependencies
import Fetch
import FetchURLSession
import FlavorResponses
import Foundation
import JSONUtilities
import Testing

@Suite(.serialized)
struct ResponsesToolLoopIntegrationTests {
  @Test("GPT-5.4 can read a file via streamed tool calling", .timeLimit(.minutes(3)))
  func gpt54ReadsFileViaToolLoop() async throws {
    let apiKey = try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"], "Set OPENAI_API_KEY before running this integration test.")

    let targetFile = "/Users/selveskii/Developer/WinterTC/wuhu-umbrella/wuhu-ai/Tests/WuhuAITests/AnthropicToolLoopIntegrationTests.swift"
    let expectedSecret = "marigold-squid-4821"
    #expect(FileManager.default.fileExists(atPath: targetFile))

    let model = Model.responses(id: "gpt-5.4")
    let target = ModelTarget(
      model: model,
      sensitiveHeaders: [
        "Authorization": "Bearer \(apiKey)"
      ]
    )

    var input = Input(
      instructions: "You are a careful coding agent. You must use the provided tool to inspect files. Do not guess. Once you know the answer, reply with only the secret string.",
      messages: [
        .user(
          .init(
            content: [
              .text(
                .init(
                  text: "What is the hard-coded secret string that appears in \(targetFile)? Use the provided tool.")
              )
            ]
          )
        )
      ],
      tools: [Tool.readFile]
    )
    input.options.responses.reasoning = Responses.Reasoning.effort(.minimal)
    input.options.responses.store = false

    let answer = try await withDependencies {
      $0.fetch = .urlSession(URLSession(configuration: .ephemeral))
    } operation: {
      try await toolLoop(input: input, target: target, expectedReadPath: targetFile)
    }

    #expect(answer == expectedSecret)
  }
}

private func toolLoop(input initialInput: Input, target: ModelTarget, expectedReadPath: String) async throws -> String {
  var input = initialInput
  var didSeeToolCallEvent = false
  var didReadExpectedFile = false

  for _ in 1...6 {
    let stream = try await LLM.stream(input, target: target)

    for try await event in stream {
      if case .toolCallStart = event {
        didSeeToolCallEvent = true
      }
    }

    let output = try await stream.result()

    let toolCalls = output.message.items.compactMap { item -> ToolCall? in
      guard case let .toolCall(toolCall) = item else { return nil }
      return toolCall
    }

    if toolCalls.isEmpty {
      let text = output.message.items.compactMap { item -> String? in
        guard case let .text(text) = item else { return nil }
        return text.text
      }
      .joined(separator: "\n")
      .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

      #expect(didSeeToolCallEvent)
      #expect(didReadExpectedFile)
      return text
    }

    input.messages.append(.assistant(output.message))

    for toolCall in toolCalls {
      let toolResult = try executeToolCall(toolCall, expectedReadPath: expectedReadPath, didReadExpectedFile: &didReadExpectedFile)
      input.messages.append(.toolResult(toolResult))
    }
  }

  Issue.record("Tool loop exhausted before the model produced a final answer.")
  return ""
}

private func executeToolCall(
  _ toolCall: ToolCall,
  expectedReadPath: String,
  didReadExpectedFile: inout Bool
) throws -> ToolResultMessage {
  switch toolCall.name {
  case "read_file":
    guard let path = toolCall.arguments.object?["path"]?.stringValue else {
      return ToolResultMessage(
        toolCallID: toolCall.id,
        toolName: toolCall.name,
        content: [
          .text(.init(text: "Missing required string argument: path"))
        ],
        isError: true
      )
    }

    let content = try String(contentsOfFile: path, encoding: .utf8)
    if path == expectedReadPath {
      didReadExpectedFile = true
    }

    return ToolResultMessage(
      toolCallID: toolCall.id,
      toolName: toolCall.name,
      content: [
        .text(.init(text: content))
      ]
    )

  default:
    return ToolResultMessage(
      toolCallID: toolCall.id,
      toolName: toolCall.name,
      content: [
        .text(.init(text: "Unsupported tool: \(toolCall.name)"))
      ],
      isError: true
    )
  }
}

private extension Tool {
  static let readFile = Tool(
    name: "read_file",
    description: "Read the UTF-8 contents of a file at an absolute path.",
    inputSchema: JSONValue.object([
      "type": JSONValue.string("object"),
      "properties": JSONValue.object([
        "path": JSONValue.object([
          "type": JSONValue.string("string"),
          "description": JSONValue.string("Absolute file path to read.")
        ])
      ]),
      "required": JSONValue.array([
        JSONValue.string("path")
      ]),
      "additionalProperties": JSONValue.bool(false)
    ])
  )
}
