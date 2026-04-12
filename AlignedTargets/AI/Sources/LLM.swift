public import AICore
internal import FlavorResponses
internal import FlavorCompletions
internal import FlavorAnthropicMessages

public enum LLM {
  public static func infer(_ input: Input, model: Model) async throws -> Output {
    switch model.flavor {
    case .responses:
      return try await Responses.infer(input, model: model)
    case .completions:
      return try await Completions.infer(input, model: model)
    case .anthropicMessages:
      return try await AnthropicMessages.infer(input, model: model)
    case let flavor:
      throw AIError.unsupportedFlavor(flavor)
    }
  }

  public static func stream(_ input: Input, model: Model) async throws -> OutputStream {
    switch model.flavor {
    case .responses:
      return try await Responses.stream(input, model: model)
    case .completions:
      return try await Completions.stream(input, model: model)
    case .anthropicMessages:
      return try await AnthropicMessages.stream(input, model: model)
    case let flavor:
      throw AIError.unsupportedFlavor(flavor)
    }
  }
}
