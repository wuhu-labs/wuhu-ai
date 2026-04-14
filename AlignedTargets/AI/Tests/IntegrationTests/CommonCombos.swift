import AICore
import Foundation
import Testing

enum CommonCombos: String, CaseIterable, Sendable {
  case `completions-gpt 4.1 mini`
  case `responses-gpt 5.4`
  case `anthropic-opus 4.5`

  static let smokeModels: [Self] = [
    .`completions-gpt 4.1 mini`,
    .`responses-gpt 5.4`,
    .`anthropic-opus 4.5`,
  ]

  var modelName: String {
    self.rawValue
  }

  var modelTarget: ModelTarget {
    switch self {
    case .`completions-gpt 4.1 mini`:
      return ModelTarget(
        model: .completions(
          id: "gpt-4.1-mini",
          baseURL: URL(string: "https://api.openai.com/v1")!
        ),
        sensitiveHeaders: [
          "Authorization": "Bearer \(apiKey)",
        ]
      )

    case .`responses-gpt 5.4`:
      return ModelTarget(
        model: .responses(id: "gpt-5.4"),
        sensitiveHeaders: [
          "Authorization": "Bearer \(apiKey)",
        ]
      )

    case .`anthropic-opus 4.5`:
      return ModelTarget(
        model: .anthropicMessages(id: "claude-opus-4-5-20251101"),
        headers: [
          "anthropic-version": "2023-06-01",
        ],
        sensitiveHeaders: [
          "x-api-key": apiKey,
        ]
      )
    }
  }

  var apiKey: String {
    "abc123"
  }

  func configure(_ input: inout Input) {
    switch self {
    case .`completions-gpt 4.1 mini`:
      input.options.completions.store = false
      input.options.completions.toolChoice = .automatic

    case .`responses-gpt 5.4`:
      input.options.responses.reasoning = .effort(.minimal)
      input.options.responses.store = false

    case .`anthropic-opus 4.5`:
      break
    }
  }
}

extension CommonCombos: CustomTestStringConvertible {
  var testDescription: String {
    self.rawValue
  }
}
