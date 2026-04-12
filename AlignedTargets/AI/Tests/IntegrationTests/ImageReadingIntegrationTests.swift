import AI
import AICore
import Dependencies
import Foundation
import Testing

struct ImageReadingIntegrationTests {
  @Test(
    "Smoke model can count dogs in an image",
    .timeLimit(.minutes(3)),
    arguments: CommonCombos.smokeModels
  )
  func imageReading(combo: CommonCombos) async throws {
    try await assertImageReading(for: combo, testName: "image-reading")
  }
}

private func assertImageReading(
  for combo: CommonCombos,
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
                text: "How many dogs are visible in this image? Answer with a number only."
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
  combo.configure(&input)

  let recordingContext = try IntegrationTestRecordingContext(
    testName: testName,
    modelName: combo.modelName,
    sourceFilePath: sourceFilePath
  )

  let answer = try await withDependencies {
    $0.fetch = recordingContext.fetchClient
  } operation: {
    let output = try await LLM.infer(input, target: combo.modelTarget)
    return output.message.items.compactMap { item -> String? in
      guard case let .text(text) = item else { return nil }
      return text.text
    }
    .joined(separator: "\n")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  #expect(!answer.isEmpty)
  let normalizedAnswer = answer.lowercased()
  #expect(normalizedAnswer.contains("3") || normalizedAnswer.contains("three"))
}

private func fixtureData(named fileName: String, sourceFilePath: StaticString) throws -> Data {
  let baseURL = URL(fileURLWithPath: "\(sourceFilePath)")
    .deletingLastPathComponent()
  return try Data(contentsOf: baseURL.appendingPathComponent(fileName, isDirectory: false))
}
