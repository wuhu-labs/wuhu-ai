public import Foundation
public import AICore
public import JSONUtilities

public enum Responses {
  public struct Scope: Sendable, Hashable {
    public var promptCacheKey: String?
    public var previousResponseID: String?
    public var store: Bool?
    public var reasoning: Reasoning
    public var serviceTier: ServiceTier?

    public init(
      promptCacheKey: String? = nil,
      previousResponseID: String? = nil,
      store: Bool? = nil,
      reasoning: Reasoning = .disabled,
      serviceTier: ServiceTier? = nil
    ) {
      self.promptCacheKey = promptCacheKey
      self.previousResponseID = previousResponseID
      self.store = store
      self.reasoning = reasoning
      self.serviceTier = serviceTier
    }
  }

  public enum Reasoning: Sendable, Hashable {
    case disabled
    case effort(Effort, summary: Summary = .automatic)
  }

  public enum Effort: String, Sendable, Hashable {
    case minimal
    case low
    case medium
    case high
    case xhigh
  }

  public enum Summary: String, Sendable, Hashable {
    case automatic
    case concise
    case detailed
  }

  public enum ServiceTier: String, Sendable, Hashable {
    case automatic
    case defaultTier
    case flex
    case priority
  }

  public struct Parser: Sendable {
    public init(model: Model) {
      self.model = model
    }

    public mutating func consume(_ event: JSONValue) throws -> [OutputEvent] {
      _ = event
      throw AIError.unimplemented("Responses.Parser.consume")
    }

    public mutating func finish() throws -> Output {
      throw AIError.unimplemented("Responses.Parser.finish")
    }

    var model: Model
  }

  public static func infer(_ input: Input, model: Model) async throws -> Output {
    _ = input
    try ensureFlavor(model)
    throw AIError.unimplemented("Responses.infer")
  }

  public static func stream(_ input: Input, model: Model) async throws -> AICore.OutputStream {
    _ = input
    try ensureFlavor(model)
    throw AIError.unimplemented("Responses.stream")
  }

  public static func encode(_ input: Input, model: Model) throws -> JSONValue {
    _ = input
    try ensureFlavor(model)
    throw AIError.unimplemented("Responses.encode")
  }

  public static func decode(_ response: JSONValue, model: Model) throws -> Output {
    _ = response
    try ensureFlavor(model)
    throw AIError.unimplemented("Responses.decode")
  }

  public static func makeStreamingParser(model: Model) -> Parser {
    Parser(model: model)
  }

  static func ensureFlavor(_ model: Model) throws {
    guard model.flavor == .responses else {
      throw AIError.unsupportedModelFlavor(expected: .responses, actual: model.flavor)
    }
  }
}

public extension Input.Options {
  var responses: Responses.Scope {
    get { self[key: ResponsesScopeKey.self] }
    set { self[key: ResponsesScopeKey.self] = newValue }
  }
}

package enum ResponsesScopeKey: OptionScopeKey {
  package static let defaultValue = Responses.Scope()
}

public extension Capabilities {
  static let responses = Self(
    input: [.text, .image, .video],
    output: [.text, .reasoning, .toolCall],
    supportsTools: true,
    supportsStreaming: true
  )
}

public extension Model {
  static func responses(
    id: String,
    baseURL: URL = URL(string: "https://api.openai.com/v1")!,
    defaultHeaders: [String: String] = [:],
    capabilities: Capabilities = .responses,
    limits: Limits = .init()
  ) -> Model {
    Model(
      id: id,
      flavor: .responses,
      endpoint: .init(baseURL: baseURL, defaultHeaders: defaultHeaders),
      capabilities: capabilities,
      limits: limits
    )
  }
}
