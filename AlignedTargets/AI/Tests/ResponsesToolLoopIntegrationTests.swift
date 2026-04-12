import AI
import AICore
import Dependencies
import FetchURLSession
import FlavorAnthropicMessages
import FlavorCompletions
import FlavorResponses
import Foundation
import JSONUtilities
import Testing

@Suite(.serialized)
struct ToolLoopIntegrationTests {
  @Test("Responses flavor can discover the secret via ls/read tools", .timeLimit(.minutes(3)))
  func responsesToolLoop() async throws {
    try await assertToolLoop(for: .responses)
  }

  @Test("Anthropic Messages flavor can discover the secret via ls/read tools", .timeLimit(.minutes(3)))
  func anthropicMessagesToolLoop() async throws {
    try await assertToolLoop(for: .anthropicMessages)
  }

  @Test("Completions flavor can discover the secret via ls/read tools", .timeLimit(.minutes(3)))
  func completionsToolLoop() async throws {
    try await assertToolLoop(for: .completions)
  }
}

private enum FlavorUnderTest {
  case responses
  case anthropicMessages
  case completions

  var modelTarget: ModelTarget {
    get throws {
      switch self {
      case .responses:
        return ModelTarget(
          model: .responses(id: "gpt-5.4"),
          sensitiveHeaders: [
            "Authorization": "Bearer \(try self.apiKey)",
          ]
        )

      case .anthropicMessages:
        return ModelTarget(
          model: .anthropicMessages(id: "claude-opus-4-5-20251101"),
          headers: [
            "anthropic-version": "2023-06-01",
          ],
          sensitiveHeaders: [
            "x-api-key": try self.apiKey,
          ]
        )

      case .completions:
        return ModelTarget(
          model: .completions(
            id: "gpt-4.1",
            baseURL: URL(string: "https://api.openai.com/v1")!
          ),
          sensitiveHeaders: [
            "Authorization": "Bearer \(try self.apiKey)",
          ]
        )
      }
    }
  }

  var apiKey: String {
    get throws {
      switch self {
      case .responses, .completions:
        return try #require(
          ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
          "Set OPENAI_API_KEY before running these integration tests."
        )

      case .anthropicMessages:
        return try #require(
          ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
          "Set ANTHROPIC_API_KEY before running these integration tests."
        )
      }
    }
  }

  func configure(_ input: inout Input) {
    switch self {
    case .responses:
      input.options.responses.reasoning = .effort(.minimal)
      input.options.responses.store = false

    case .anthropicMessages:
      break

    case .completions:
      input.options.completions.store = false
      input.options.completions.toolChoice = .automatic
    }
  }
}

private func assertToolLoop(for flavor: FlavorUnderTest) async throws {
  let secret = "marigold-squid-4821"
  let fileSystem = DictionaryFileSystem(files: [
    "3.txt": "prime",
    "5.txt": "prime",
    "7.txt": "prime",
    "9.txt": secret,
  ])

  var input = Input(
    instructions: """
      You are a careful file-inspecting agent.
      You must use the provided tools to inspect the file system.
      Do not assume any filenames exist before listing them.
      Once you know the answer, reply with only the file content.
      """,
    messages: [
      .user(
        .init(
          content: [
            .text(
              .init(
                text: "Tell me the content of the only file whose filename is not a prime"
              )
            )
          ]
        )
      )
    ],
    tools: [Tool.ls, Tool.read]
  )
  flavor.configure(&input)

  let result = try await withDependencies {
    $0.fetch = .urlSession(URLSession(configuration: .ephemeral))
  } operation: {
    try await toolLoop(input: input, target: try flavor.modelTarget, fileSystem: fileSystem)
  }

  #expect(result.executedToolNames.contains("ls"))
  #expect(result.executedToolNames.contains("read"))
  #expect(result.readPaths.contains("9.txt"))
  #expect(result.answer == secret)
}

private struct ToolLoopResult {
  var answer: String
  var executedToolNames: [String]
  var readPaths: [String]
}

private func toolLoop(
  input initialInput: Input,
  target: ModelTarget,
  fileSystem: DictionaryFileSystem
) async throws -> ToolLoopResult {
  var input = initialInput
  var executedToolNames: [String] = []
  var readPaths: [String] = []

  for _ in 1...8 {
    let stream = try await LLM.stream(input, target: target)

    for try await _ in stream {}

    let output = try await stream.result()
    let toolCalls = output.message.items.compactMap { item -> ToolCall? in
      guard case let .toolCall(toolCall) = item else { return nil }
      return toolCall
    }

    if toolCalls.isEmpty {
      let answer = output.message.items.compactMap { item -> String? in
        guard case let .text(text) = item else { return nil }
        return text.text
      }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)

      return ToolLoopResult(
        answer: answer,
        executedToolNames: executedToolNames,
        readPaths: readPaths
      )
    }

    input.messages.append(.assistant(output.message))

    for toolCall in toolCalls {
      executedToolNames.append(toolCall.name)
      let result = fileSystem.execute(toolCall, readPaths: &readPaths)
      input.messages.append(.toolResult(result))
    }
  }

  Issue.record("Tool loop exhausted before the model produced a final answer.")
  return ToolLoopResult(answer: "", executedToolNames: executedToolNames, readPaths: readPaths)
}

private struct DictionaryFileSystem {
  let files: [String: String]

  func execute(_ toolCall: ToolCall, readPaths: inout [String]) -> ToolResultMessage {
    switch toolCall.name {
    case "ls":
      return ToolResultMessage(
        toolCallID: toolCall.id,
        toolName: toolCall.name,
        content: [
          .text(.init(text: self.files.keys.sorted().joined(separator: "\n")))
        ]
      )

    case "read":
      guard let path = normalizedPath(from: toolCall.arguments) else {
        return ToolResultMessage(
          toolCallID: toolCall.id,
          toolName: toolCall.name,
          content: [
            .text(.init(text: "Missing required string argument: path"))
          ],
          isError: true
        )
      }

      readPaths.append(path)

      guard let content = self.files[path] else {
        return ToolResultMessage(
          toolCallID: toolCall.id,
          toolName: toolCall.name,
          content: [
            .text(.init(text: "No such file: \(path)"))
          ],
          isError: true
        )
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

  private func normalizedPath(from arguments: JSONValue) -> String? {
    guard let rawPath = arguments.object?["path"]?.stringValue else { return nil }

    var path = rawPath
    while path.hasPrefix("./") {
      path.removeFirst(2)
    }
    while path.hasPrefix("/") {
      path.removeFirst()
    }

    return path
  }
}

private extension Tool {
  static let ls = Tool(
    name: "ls",
    description: "List files in the root directory.",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object([:]),
      "additionalProperties": .bool(false),
    ])
  )

  static let read = Tool(
    name: "read",
    description: "Read the contents of a file in the root directory.",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object([
        "path": .object([
          "type": .string("string"),
          "description": .string("The file name to read, such as 9.txt."),
        ])
      ]),
      "required": .array([
        .string("path")
      ]),
      "additionalProperties": .bool(false),
    ])
  )
}
