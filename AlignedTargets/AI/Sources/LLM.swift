public import AICore
internal import FlavorResponses
internal import FlavorCompletions
internal import FlavorAnthropicMessages

public enum LLM {
  public static func infer(_ input: Input, target: ModelTarget) async throws -> Output {
    switch target.model.flavor {
    case .responses:
      return try await Responses.infer(input, target: target)
    case .completions:
      return try await Completions.infer(input, target: target)
    case .anthropicMessages:
      return try await AnthropicMessages.infer(input, target: target)
    case let flavor:
      throw AIError.unsupportedFlavor(flavor)
    }
  }

  public static func stream(_ input: Input, target: ModelTarget) async throws -> OutputStream {
    switch target.model.flavor {
    case .responses:
      return try await Responses.stream(input, target: target)
    case .completions:
      return try await Completions.stream(input, target: target)
    case .anthropicMessages:
      return try await AnthropicMessages.stream(input, target: target)
    case let flavor:
      throw AIError.unsupportedFlavor(flavor)
    }
  }
}
