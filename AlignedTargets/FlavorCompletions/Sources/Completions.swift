public import Foundation
public import AICore
public import JSONUtilities

public enum Completions {
  public struct Scope: Sendable, Hashable {
    public var store: Bool?
    public var toolChoice: ToolChoice?
    public var reasoning: Reasoning

    public init(
      store: Bool? = nil,
      toolChoice: ToolChoice? = nil,
      reasoning: Reasoning = .disabled
    ) {
      self.store = store
      self.toolChoice = toolChoice
      self.reasoning = reasoning
    }
  }

  public enum ToolChoice: Sendable, Hashable {
    case automatic
    case none
    case required
    case tool(String)
  }

  public enum Reasoning: Sendable, Hashable {
    case disabled
    case effort(Effort)
  }

  public enum Effort: String, Sendable, Hashable {
    case minimal
    case low
    case medium
    case high
    case xhigh
  }

  public struct Compatibility: Sendable, Hashable {
    public var supportsStore: Bool
    public var supportsDeveloperRole: Bool
    public var supportsReasoningEffort: Bool
    public var supportsUsageInStreaming: Bool
    public var supportsStrictTools: Bool
    public var maxTokensField: MaxTokensField
    public var requiresToolResultName: Bool
    public var requiresAssistantAfterToolResult: Bool
    public var replaysReasoningAsPlainText: Bool
    public var thinkingFormat: ThinkingFormat

    public init(
      supportsStore: Bool = true,
      supportsDeveloperRole: Bool = true,
      supportsReasoningEffort: Bool = true,
      supportsUsageInStreaming: Bool = true,
      supportsStrictTools: Bool = true,
      maxTokensField: MaxTokensField = .maxCompletionTokens,
      requiresToolResultName: Bool = false,
      requiresAssistantAfterToolResult: Bool = false,
      replaysReasoningAsPlainText: Bool = false,
      thinkingFormat: ThinkingFormat = .openAI
    ) {
      self.supportsStore = supportsStore
      self.supportsDeveloperRole = supportsDeveloperRole
      self.supportsReasoningEffort = supportsReasoningEffort
      self.supportsUsageInStreaming = supportsUsageInStreaming
      self.supportsStrictTools = supportsStrictTools
      self.maxTokensField = maxTokensField
      self.requiresToolResultName = requiresToolResultName
      self.requiresAssistantAfterToolResult = requiresAssistantAfterToolResult
      self.replaysReasoningAsPlainText = replaysReasoningAsPlainText
      self.thinkingFormat = thinkingFormat
    }
  }

  public enum MaxTokensField: Sendable, Hashable {
    case maxCompletionTokens
    case maxTokens
  }

  public enum ThinkingFormat: Sendable, Hashable {
    case openAI
    case openRouter
    case zAI
    case qwen
    case qwenChatTemplate
  }

  public struct Parser: Sendable {
    public init(model: Model) {
      self.model = model
    }

    public mutating func consume(_ event: JSONValue) throws -> [OutputEvent] {
      _ = event
      throw AIError.unimplemented("Completions.Parser.consume")
    }

    public mutating func finish() throws -> Output {
      throw AIError.unimplemented("Completions.Parser.finish")
    }

    var model: Model
  }

  public static func infer(_ input: Input, target: ModelTarget) async throws -> Output {
    try await CompletionsRuntime().infer(input, target: target)
  }

  public static func stream(_ input: Input, target: ModelTarget) async throws -> AICore.OutputStream {
    try await CompletionsRuntime().stream(input, target: target)
  }

  public static func encode(_ input: Input, model: Model) throws -> JSONValue {
    try _encode(input, model: model)
  }

  public static func decode(_ response: JSONValue, model: Model) throws -> Output {
    try _decode(response, model: model)
  }

  public static func makeStreamingParser(model: Model) -> Parser {
    Parser(model: model)
  }

  static func ensureFlavor(_ model: Model) throws {
    guard model.flavor == .completions else {
      throw AIError.unsupportedModelFlavor(expected: .completions, actual: model.flavor)
    }
  }
}

public extension Input.Options {
  var completions: Completions.Scope {
    get { self[key: CompletionsScopeKey.self] }
    set { self[key: CompletionsScopeKey.self] = newValue }
  }
}

package enum CompletionsScopeKey: OptionScopeKey {
  package static let defaultValue = Completions.Scope()
}

public extension Capabilities {
  static let completions = Self(
    input: [.text, .image, .video],
    output: [.text, .reasoning, .toolCall],
    supportsTools: true,
    supportsStreaming: true
  )
}

public extension Model {
  static func completions(
    id: String,
    baseURL: URL,
    defaultHeaders: [String: String] = [:],
    capabilities: Capabilities = .completions,
    limits: Limits = .init()
  ) -> Model {
    Model(
      id: id,
      flavor: .completions,
      endpoint: .init(baseURL: baseURL),
      defaultHeaders: defaultHeaders,
      capabilities: capabilities,
      limits: limits
    )
  }
}
