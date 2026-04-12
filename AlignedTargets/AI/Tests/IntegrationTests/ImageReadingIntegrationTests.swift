import AI
import AICore
import Dependencies
import Foundation
import Testing

struct ImageReadingIntegrationTests {
  @Test("Responses flavor can count dogs in an image", .timeLimit(.minutes(3)))
  func responsesImageReading() async throws {
    try await assertImageReading(for: .responses, testName: "responsesImageReading")
  }

  @Test("Anthropic Messages flavor can count dogs in an image", .timeLimit(.minutes(3)))
  func anthropicMessagesImageReading() async throws {
    try await assertImageReading(for: .anthropicMessages, testName: "anthropicMessagesImageReading")
  }

  @Test("Completions flavor can count dogs in an image", .timeLimit(.minutes(3)))
  func completionsImageReading() async throws {
    try await assertImageReading(for: .completions, testName: "completionsImageReading")
  }
}

private func assertImageReading(
  for flavor: FlavorUnderTest,
  testName: String,
  sourceFilePath: StaticString = #filePath
) async throws {
  let imageData = try fixtureData(named: "image-test.jpg", sourceFilePath: sourceFilePath)

  var input = Input(
    instructions: """
    You are a careful image-inspecting assistant.
    Look at the provided image and answer the user's question.
    Reply with only the number of dogs visible in the image, as a single digit.
    """,
    messages: [
      .user(
        .init(
          content: [
            .text(
              .init(
                text: "How many dogs are visible in this image?"
              )
            ),
            .media(
              .init(
                kind: .image,
                source: .data(imageData),
                mimeType: "image/jpeg"
              )
            ),
          ]
        )
      ),
    ]
  )
  input.options.maxOutputTokens = 16
  flavor.configure(&input)
  if case .responses = flavor {
    input.options.responses.reasoning = .disabled
  }

  let recordingContext = try IntegrationTestRecordingContext(
    testName: testName,
    sourceFilePath: sourceFilePath
  )

  let answer = try await withDependencies {
    $0.fetch = recordingContext.fetchClient
  } operation: {
    let output = try await LLM.infer(input, target: flavor.modelTarget)
    return output.message.items.compactMap { item -> String? in
      guard case let .text(text) = item else { return nil }
      return text.text
    }
    .joined(separator: "\n")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  #expect(!answer.isEmpty)
  #expect(dogCount(in: answer) == 3)
}

private func fixtureData(named fileName: String, sourceFilePath: StaticString) throws -> Data {
  let baseURL = URL(fileURLWithPath: "\(sourceFilePath)")
    .deletingLastPathComponent()
  return try Data(contentsOf: baseURL.appendingPathComponent(fileName, isDirectory: false))
}

private func dogCount(in answer: String) -> Int? {
  if let digit = answer.first(where: { $0.isNumber })?.wholeNumberValue {
    return digit
  }

  let normalized = answer
    .lowercased()
    .replacingOccurrences(of: "[^a-z]+", with: " ", options: .regularExpression)
    .split(separator: " ")

  for token in normalized {
    switch token {
    case "zero": return 0
    case "one": return 1
    case "two": return 2
    case "three": return 3
    case "four": return 4
    case "five": return 5
    case "six": return 6
    case "seven": return 7
    case "eight": return 8
    case "nine": return 9
    default: continue
    }
  }

  return nil
}
