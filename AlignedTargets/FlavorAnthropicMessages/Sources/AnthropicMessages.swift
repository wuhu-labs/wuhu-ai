public import Foundation
public import AICore
public import JSONUtilities

public enum AnthropicMessages {
  public struct Scope: Sendable, Hashable {
    public var promptCaching: PromptCaching
    public var thinking: Thinking
    public var interleavedThinking: Bool
    public var toolChoice: ToolChoice?

    public init(
      promptCaching: PromptCaching = .disabled,
      thinking: Thinking = .disabled,
      interleavedThinking: Bool = true,
      toolChoice: ToolChoice? = nil
    ) {
      self.promptCaching = promptCaching
      self.thinking = thinking
      self.interleavedThinking = interleavedThinking
      self.toolChoice = toolChoice
    }
  }

  public enum PromptCaching: Sendable, Hashable {
    case disabled
    case automatic
    case explicitBreakpoints(sendBetaHeader: Bool = false)
  }

  public enum Thinking: Sendable, Hashable {
    case disabled
    case enabled(budgetTokens: Int? = nil, effort: Effort? = nil)
  }

  public enum Effort: String, Sendable, Hashable {
    case low
    case medium
    case high
    case max
  }

  public enum ToolChoice: Sendable, Hashable {
    case automatic
    case any
    case none
    case tool(String)
  }

  public struct Parser: Sendable {
    public init(model: Model) {
      self.model = model
    }

    public mutating func consume(_ event: JSONValue) throws -> [OutputEvent] {
      _ = event
      throw AIError.unimplemented("AnthropicMessages.Parser.consume")
    }

    public mutating func finish() throws -> Output {
      throw AIError.unimplemented("AnthropicMessages.Parser.finish")
    }

    var model: Model
  }

  public static func infer(_ input: Input, model: Model) async throws -> Output {
    _ = input
    try ensureFlavor(model)
    throw AIError.unimplemented("AnthropicMessages.infer")
  }

  public static func stream(_ input: Input, model: Model) async throws -> AICore.OutputStream {
    _ = input
    try ensureFlavor(model)
    throw AIError.unimplemented("AnthropicMessages.stream")
  }

  public static func encode(_ input: Input, model: Model) throws -> JSONValue {
    _ = input
    try ensureFlavor(model)
    throw AIError.unimplemented("AnthropicMessages.encode")
  }

  public static func decode(_ response: JSONValue, model: Model) throws -> Output {
    _ = response
    try ensureFlavor(model)
    throw AIError.unimplemented("AnthropicMessages.decode")
  }

  public static func makeStreamingParser(model: Model) -> Parser {
    Parser(model: model)
  }

  static func ensureFlavor(_ model: Model) throws {
    guard model.flavor == .anthropicMessages else {
      throw AIError.unsupportedModelFlavor(expected: .anthropicMessages, actual: model.flavor)
    }
  }
}

public extension Input.Options {
  var anthropicMessages: AnthropicMessages.Scope {
    get { self[key: AnthropicMessagesScopeKey.self] }
    set { self[key: AnthropicMessagesScopeKey.self] = newValue }
  }
}

package enum AnthropicMessagesScopeKey: OptionScopeKey {
  package static let defaultValue = AnthropicMessages.Scope()
}

public extension Capabilities {
  static let anthropicMessages = Self(
    input: [.text, .image],
    output: [.text, .reasoning, .toolCall],
    supportsTools: true,
    supportsStreaming: true
  )
}

public extension Model {
  static func anthropicMessages(
    id: String,
    baseURL: URL = URL(string: "https://api.anthropic.com/v1")!,
    defaultHeaders: [String: String] = [:],
    capabilities: Capabilities = .anthropicMessages,
    limits: Limits = .init()
  ) -> Model {
    Model(
      id: id,
      flavor: .anthropicMessages,
      endpoint: .init(baseURL: baseURL, defaultHeaders: defaultHeaders),
      capabilities: capabilities,
      limits: limits
    )
  }
}
