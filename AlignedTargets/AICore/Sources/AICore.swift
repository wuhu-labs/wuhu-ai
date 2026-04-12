public import Foundation
public import JSONUtilities

public enum APIFlavor: String, Sendable, Hashable, CaseIterable {
  case responses
  case completions
  case anthropicMessages
  case gemini
}

public struct Model: Sendable, Hashable {
  public var id: String
  public var flavor: APIFlavor
  public var endpoint: Endpoint
  public var defaultHeaders: [String: String]
  public var capabilities: Capabilities
  public var limits: Limits

  public init(
    id: String,
    flavor: APIFlavor,
    endpoint: Endpoint,
    defaultHeaders: [String: String] = [:],
    capabilities: Capabilities,
    limits: Limits = .init()
  ) {
    self.id = id
    self.flavor = flavor
    self.endpoint = endpoint
    self.defaultHeaders = defaultHeaders
    self.capabilities = capabilities
    self.limits = limits
  }
}

public struct ModelTarget: Sendable {
  public var model: Model
  public var headers: [String: String]
  public var sensitiveHeaders: [String: String]

  public init(
    model: Model,
    headers: [String: String] = [:],
    sensitiveHeaders: [String: String] = [:]
  ) {
    self.model = model
    self.headers = headers
    self.sensitiveHeaders = sensitiveHeaders
  }
}

public struct Endpoint: Sendable, Hashable {
  public var baseURL: URL

  public init(baseURL: URL) {
    self.baseURL = baseURL
  }
}

public struct Capabilities: Sendable, Hashable {
  public var input: Set<InputCapability>
  public var output: Set<OutputCapability>
  public var supportsTools: Bool
  public var supportsStreaming: Bool

  public init(
    input: Set<InputCapability> = [.text],
    output: Set<OutputCapability> = [.text],
    supportsTools: Bool = false,
    supportsStreaming: Bool = true
  ) {
    self.input = input
    self.output = output
    self.supportsTools = supportsTools
    self.supportsStreaming = supportsStreaming
  }
}

public enum InputCapability: String, Sendable, Hashable {
  case text
  case image
  case video
  case audio
  case document
}

public enum OutputCapability: String, Sendable, Hashable {
  case text
  case reasoning
  case toolCall
  case image
  case audio
}

public struct Limits: Sendable, Hashable {
  public var contextWindow: Int?
  public var maxOutputTokens: Int?

  public init(contextWindow: Int? = nil, maxOutputTokens: Int? = nil) {
    self.contextWindow = contextWindow
    self.maxOutputTokens = maxOutputTokens
  }
}

public struct Input: Sendable {
  public struct Options: Sendable {
    package var scopeStorage: [ObjectIdentifier: any Sendable]
    public var temperature: Double?
    public var maxOutputTokens: Int?
    public var additionalHeaders: [String: String]

    public init(
      temperature: Double? = nil,
      maxOutputTokens: Int? = nil,
      additionalHeaders: [String: String] = [:]
    ) {
      self.scopeStorage = [:]
      self.temperature = temperature
      self.maxOutputTokens = maxOutputTokens
      self.additionalHeaders = additionalHeaders
    }

    package subscript<Key: OptionScopeKey>(key keyType: Key.Type) -> Key.Value {
      get {
        self.scopeStorage[ObjectIdentifier(keyType)] as? Key.Value ?? Key.defaultValue
      }
      set {
        self.scopeStorage[ObjectIdentifier(keyType)] = newValue
      }
    }
  }

  public var instructions: String?
  public var messages: [Message]
  public var tools: [Tool]
  public var options: Options

  public init(
    instructions: String? = nil,
    messages: [Message] = [],
    tools: [Tool] = [],
    options: Options = .init()
  ) {
    self.instructions = instructions
    self.messages = messages
    self.tools = tools
    self.options = options
  }
}

package protocol OptionScopeKey {
  associatedtype Value: Sendable
  static var defaultValue: Value { get }
}

public enum Message: Sendable, Hashable {
  case user(UserMessage)
  case assistant(AssistantMessage)
  case toolResult(ToolResultMessage)
}

public struct UserMessage: Sendable, Hashable {
  public var content: [InputPart]
  public var timestamp: Date

  public init(content: [InputPart], timestamp: Date = Date()) {
    self.content = content
    self.timestamp = timestamp
  }
}

public struct AssistantMessage: Sendable, Hashable {
  public var items: [OutputItem]
  public var phase: String?
  public var responseID: String?
  public var stopReason: StopReason?
  public var timestamp: Date

  public init(
    items: [OutputItem] = [],
    phase: String? = nil,
    responseID: String? = nil,
    stopReason: StopReason? = nil,
    timestamp: Date = Date()
  ) {
    self.items = items
    self.phase = phase
    self.responseID = responseID
    self.stopReason = stopReason
    self.timestamp = timestamp
  }
}

public struct ToolResultMessage: Sendable, Hashable {
  public var toolCallID: String
  public var toolName: String
  public var content: [InputPart]
  public var isError: Bool
  public var timestamp: Date

  public init(
    toolCallID: String,
    toolName: String,
    content: [InputPart],
    isError: Bool = false,
    timestamp: Date = Date()
  ) {
    self.toolCallID = toolCallID
    self.toolName = toolName
    self.content = content
    self.isError = isError
    self.timestamp = timestamp
  }
}

public enum InputPart: Sendable, Hashable {
  case text(TextPart)
  case media(MediaPart)
}

public struct TextPart: Sendable, Hashable {
  public var text: String
  public var promptCacheBreakpoint: Bool

  public init(text: String, promptCacheBreakpoint: Bool = false) {
    self.text = text
    self.promptCacheBreakpoint = promptCacheBreakpoint
  }
}

public struct MediaPart: Sendable, Hashable {
  public var kind: MediaKind
  public var source: MediaSource
  public var mimeType: String
  public var promptCacheBreakpoint: Bool

  public init(
    kind: MediaKind,
    source: MediaSource,
    mimeType: String,
    promptCacheBreakpoint: Bool = false
  ) {
    self.kind = kind
    self.source = source
    self.mimeType = mimeType
    self.promptCacheBreakpoint = promptCacheBreakpoint
  }
}

public enum MediaKind: String, Sendable, Hashable {
  case image
  case video
  case audio
  case document
}

public enum MediaSource: Sendable, Hashable {
  case data(Data)
  case remoteURL(URL)
  case fileReference(FileReference)
}

public struct FileReference: Sendable, Hashable {
  public var id: String
  public var url: URL?

  public init(id: String, url: URL? = nil) {
    self.id = id
    self.url = url
  }
}

public struct Tool: Sendable, Hashable {
  public var name: String
  public var description: String
  public var inputSchema: JSONValue

  public init(name: String, description: String, inputSchema: JSONValue) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
  }
}

public struct Output: Sendable, Hashable {
  public var model: Model
  public var message: AssistantMessage
  public var usage: Usage?

  public init(model: Model, message: AssistantMessage, usage: Usage? = nil) {
    self.model = model
    self.message = message
    self.usage = usage
  }
}

public enum OutputItem: Sendable, Hashable {
  case text(TextOutput)
  case reasoning(ReasoningOutput)
  case toolCall(ToolCall)
}

public struct TextOutput: Sendable, Hashable {
  public var text: String
  public var signature: String?

  public init(text: String, signature: String? = nil) {
    self.text = text
    self.signature = signature
  }
}

public struct ReasoningOutput: Sendable, Hashable {
  public var id: String?
  public var text: String?
  public var summary: String?
  public var signature: String?
  public var redacted: Bool

  public init(
    id: String? = nil,
    text: String? = nil,
    summary: String? = nil,
    signature: String? = nil,
    redacted: Bool = false
  ) {
    self.id = id
    self.text = text
    self.summary = summary
    self.signature = signature
    self.redacted = redacted
  }
}

public struct ToolCall: Sendable, Hashable {
  public var id: String
  public var name: String
  public var arguments: JSONValue
  public var signature: String?

  public init(id: String, name: String, arguments: JSONValue, signature: String? = nil) {
    self.id = id
    self.name = name
    self.arguments = arguments
    self.signature = signature
  }
}

public enum StopReason: String, Sendable, Hashable {
  case stop
  case length
  case toolUse
  case aborted
  case error
}

public struct Usage: Sendable, Hashable {
  public var inputTokens: Int
  public var outputTokens: Int
  public var cacheReadTokens: Int
  public var cacheWriteTokens: Int
  public var totalTokens: Int

  public init(
    inputTokens: Int,
    outputTokens: Int,
    cacheReadTokens: Int = 0,
    cacheWriteTokens: Int = 0,
    totalTokens: Int
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheReadTokens = cacheReadTokens
    self.cacheWriteTokens = cacheWriteTokens
    self.totalTokens = totalTokens
  }
}

public struct OutputStream: AsyncSequence, Sendable {
  public typealias Element = OutputEvent

  package let stream: AsyncThrowingStream<OutputEvent, any Error>
  package let resultOperation: @Sendable () async throws -> Output

  package init(
    stream: AsyncThrowingStream<OutputEvent, any Error>,
    resultOperation: @escaping @Sendable () async throws -> Output
  ) {
    self.stream = stream
    self.resultOperation = resultOperation
  }

  public struct Iterator: AsyncIteratorProtocol {
    var iterator: AsyncThrowingStream<OutputEvent, any Error>.Iterator

    public mutating func next() async throws -> OutputEvent? {
      try await self.iterator.next()
    }
  }

  public func makeAsyncIterator() -> Iterator {
    Iterator(iterator: self.stream.makeAsyncIterator())
  }

  public func result() async throws -> Output {
    try await self.resultOperation()
  }
}

public enum OutputEvent: Sendable, Hashable {
  case start(partial: Output)
  case textStart(index: Int, partial: Output)
  case textDelta(index: Int, delta: String, partial: Output)
  case textEnd(index: Int, text: String, partial: Output)
  case reasoningStart(index: Int, partial: Output)
  case reasoningDelta(index: Int, delta: String, partial: Output)
  case reasoningEnd(index: Int, text: String, partial: Output)
  case toolCallStart(index: Int, partial: Output)
  case toolCallDelta(index: Int, delta: String, partial: Output)
  case toolCallEnd(index: Int, toolCall: ToolCall, partial: Output)
  case complete(Output)
  case failure(partial: Output, error: AIError)
}

public enum AIError: Error, Sendable, Hashable {
  case unsupportedFlavor(APIFlavor)
  case unsupportedModelFlavor(expected: APIFlavor, actual: APIFlavor)
  case invalidResponse(String)
  case upstream(statusCode: Int?, message: String)
  case unimplemented(String)
}

public enum Models {}
