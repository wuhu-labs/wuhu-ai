import Foundation

public enum Provider: String, Sendable {
  case openai
  case openaiCodex = "openai-codex"
  case anthropic
}

public struct Model: Sendable, Hashable {
  public var id: String
  public var provider: Provider
  public var baseURL: URL

  public init(id: String, provider: Provider, baseURL: URL? = nil) {
    self.id = id
    self.provider = provider

    if let baseURL {
      self.baseURL = baseURL
      return
    }

    switch provider {
    case .openai:
      self.baseURL = URL(string: "https://api.openai.com/v1")!
    case .openaiCodex:
      self.baseURL = URL(string: "https://chatgpt.com/backend-api")!
    case .anthropic:
      self.baseURL = URL(string: "https://api.anthropic.com/v1")!
    }
  }
}

public struct Context: Sendable, Hashable {
  public var systemPrompt: String?
  public var messages: [Message]
  public var tools: [Tool]?

  public init(systemPrompt: String? = nil, messages: [Message], tools: [Tool]? = nil) {
    self.systemPrompt = systemPrompt
    self.messages = messages
    self.tools = tools
  }
}

public struct Tool: Sendable, Hashable {
  public var name: String
  public var description: String
  /// JSON Schema (draft-07-ish) for the tool parameters.
  public var parameters: JSONValue

  public init(name: String, description: String, parameters: JSONValue) {
    self.name = name
    self.description = description
    self.parameters = parameters
  }
}

public struct ToolCall: Sendable, Hashable {
  public var id: String
  public var name: String
  public var arguments: JSONValue

  public init(id: String, name: String, arguments: JSONValue) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

/// Provider-specific reasoning content that must be replayed back to the provider in subsequent turns.
///
/// Used by providers that expose hidden or summarized reasoning state as structured content.
/// OpenAI Responses API uses `encrypted_content` and `summary`, while Anthropic Messages API
/// uses `thinking` / `redacted_thinking` blocks plus a `signature` for replay.
public struct ReasoningContent: Sendable, Hashable {
  public var id: String
  public var encryptedContent: String?
  public var summary: [JSONValue]
  public var text: String?
  public var signature: String?
  public var redactedData: String?

  public init(
    id: String,
    encryptedContent: String? = nil,
    summary: [JSONValue] = [],
    text: String? = nil,
    signature: String? = nil,
    redactedData: String? = nil,
  ) {
    self.id = id
    self.encryptedContent = encryptedContent
    self.summary = summary
    self.text = text
    self.signature = signature
    self.redactedData = redactedData
  }
}

public struct ImageContent: Sendable, Hashable {
  public var data: String // base64-encoded image data
  public var mimeType: String // "image/jpeg", "image/png", "image/gif", "image/webp"

  public init(data: String, mimeType: String) {
    self.data = data
    self.mimeType = mimeType
  }
}

public enum ContentBlock: Sendable, Hashable {
  case text(TextContent)
  case toolCall(ToolCall)
  case reasoning(ReasoningContent)
  case image(ImageContent)
}

public enum Message: Sendable, Hashable {
  case user(UserMessage)
  case assistant(AssistantMessage)
  case toolResult(ToolResultMessage)

  public var role: MessageRole {
    switch self {
    case .user:
      .user
    case .assistant:
      .assistant
    case .toolResult:
      .toolResult
    }
  }

  public var timestamp: Date {
    switch self {
    case let .user(m):
      m.timestamp
    case let .assistant(m):
      m.timestamp
    case let .toolResult(m):
      m.timestamp
    }
  }

  public static func user(_ text: String, timestamp: Date = Date()) -> Message {
    .user(.init(content: [.text(.init(text: text))], timestamp: timestamp))
  }
}

public enum MessageRole: String, Sendable, Hashable {
  case user
  case assistant
  case toolResult
}

public struct UserMessage: Sendable, Hashable {
  public var content: [ContentBlock]
  public var timestamp: Date

  public init(content: [ContentBlock], timestamp: Date = Date()) {
    self.content = content
    self.timestamp = timestamp
  }
}

public enum StopReason: String, Sendable {
  case stop
  case length
  case toolUse
  case aborted
  case error
}

public struct Usage: Sendable, Hashable {
  public var inputTokens: Int
  public var outputTokens: Int
  public var totalTokens: Int

  public init(inputTokens: Int, outputTokens: Int, totalTokens: Int) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.totalTokens = totalTokens
  }
}

public struct RequestOptions: Sendable, Hashable {
  public var temperature: Double?
  public var maxTokens: Int?
  public var apiKey: String?
  public var headers: [String: String]
  public var sessionId: String?
  public var reasoningEffort: ReasoningEffort?
  public var anthropicPromptCaching: AnthropicPromptCachingOptions?
  public var anthropicThinking: AnthropicThinkingOptions?

  public init(
    temperature: Double? = nil,
    maxTokens: Int? = nil,
    apiKey: String? = nil,
    headers: [String: String] = [:],
    sessionId: String? = nil,
    reasoningEffort: ReasoningEffort? = nil,
    anthropicPromptCaching: AnthropicPromptCachingOptions? = nil,
    anthropicThinking: AnthropicThinkingOptions? = nil,
  ) {
    self.temperature = temperature
    self.maxTokens = maxTokens
    self.apiKey = apiKey
    self.headers = headers
    self.sessionId = sessionId
    self.reasoningEffort = reasoningEffort
    self.anthropicPromptCaching = anthropicPromptCaching
    self.anthropicThinking = anthropicThinking
  }
}

public enum AnthropicPromptCachingMode: String, Sendable, Hashable {
  /// Uses Anthropic's "automatic caching" behavior: `cache_control` at the request top-level.
  case automatic
  /// Uses explicit cache breakpoints, by placing `cache_control` on individual content blocks.
  case explicitBreakpoints
}

public struct AnthropicPromptCachingOptions: Sendable, Hashable {
  public var mode: AnthropicPromptCachingMode
  /// Historically, prompt caching required setting `anthropic-beta: prompt-caching-2024-07-31`.
  /// Some deployments may still expect it.
  public var sendBetaHeader: Bool

  public init(mode: AnthropicPromptCachingMode = .automatic, sendBetaHeader: Bool = false) {
    self.mode = mode
    self.sendBetaHeader = sendBetaHeader
  }
}

public enum AnthropicThinkingMode: String, Sendable, Hashable, Codable {
  case manual
  case adaptive
}

public enum AnthropicThinkingDisplay: String, Sendable, Hashable, Codable {
  /// Returns thinking blocks with empty `text` and replayable signatures for lower latency.
  case omitted
  /// Returns provider-generated summaries in the reasoning `text` field.
  case summarized
}

public struct AnthropicThinkingOptions: Sendable, Hashable {
  public var mode: AnthropicThinkingMode
  /// Used for Anthropic manual thinking (`thinking.type = "enabled"`).
  public var budgetTokens: Int?
  /// Used for Anthropic adaptive thinking on newer models (`output_config.effort`).
  public var effort: ReasoningEffort?
  public var display: AnthropicThinkingDisplay
  /// Enables interleaved thinking by default. Older/manual flows may require a beta header.
  public var interleaved: Bool

  public init(
    mode: AnthropicThinkingMode = .manual,
    budgetTokens: Int? = nil,
    effort: ReasoningEffort? = nil,
    display: AnthropicThinkingDisplay = .summarized,
    interleaved: Bool = true,
  ) {
    self.mode = mode
    self.budgetTokens = budgetTokens
    self.effort = effort
    self.display = display
    self.interleaved = interleaved
  }
}

public enum ReasoningEffort: String, Sendable, Hashable, Codable {
  case minimal
  case low
  case medium
  case high
  case xhigh
}

public struct TextContent: Sendable, Hashable {
  public var text: String
  public var signature: String?

  public init(text: String, signature: String? = nil) {
    self.text = text
    self.signature = signature
  }
}

public struct AssistantMessage: Sendable, Hashable {
  public var provider: Provider
  public var model: String
  public var content: [ContentBlock]
  public var usage: Usage?
  public var stopReason: StopReason
  public var errorMessage: String?
  public var timestamp: Date

  public init(
    provider: Provider,
    model: String,
    content: [ContentBlock] = [],
    usage: Usage? = nil,
    stopReason: StopReason = .stop,
    errorMessage: String? = nil,
    timestamp: Date = Date(),
  ) {
    self.provider = provider
    self.model = model
    self.content = content
    self.usage = usage
    self.stopReason = stopReason
    self.errorMessage = errorMessage
    self.timestamp = timestamp
  }
}

public struct ToolResultMessage: Sendable, Hashable {
  public var toolCallId: String
  public var toolName: String
  public var content: [ContentBlock]
  public var details: JSONValue
  public var isError: Bool
  public var timestamp: Date

  public init(
    toolCallId: String,
    toolName: String,
    content: [ContentBlock],
    details: JSONValue = .object([:]),
    isError: Bool = false,
    timestamp: Date = Date(),
  ) {
    self.toolCallId = toolCallId
    self.toolName = toolName
    self.content = content
    self.details = details
    self.isError = isError
    self.timestamp = timestamp
  }
}

public enum AssistantMessageEvent: Sendable, Hashable {
  case start(partial: AssistantMessage)
  case textDelta(delta: String, partial: AssistantMessage)
  case done(message: AssistantMessage)
}

public extension ContentBlock {
  static func text(_ text: String, signature: String? = nil) -> ContentBlock {
    .text(.init(text: text, signature: signature))
  }

  static func reasoning(
    id: String,
    encryptedContent: String? = nil,
    summary: [JSONValue] = [],
    text: String? = nil,
    signature: String? = nil,
    redactedData: String? = nil,
  ) -> ContentBlock {
    .reasoning(.init(
      id: id,
      encryptedContent: encryptedContent,
      summary: summary,
      text: text,
      signature: signature,
      redactedData: redactedData,
    ))
  }

  static func image(data: String, mimeType: String) -> ContentBlock {
    .image(.init(data: data, mimeType: mimeType))
  }
}

public extension Message {
  var user: UserMessage? {
    if case let .user(m) = self { return m }
    return nil
  }

  var assistant: AssistantMessage? {
    if case let .assistant(m) = self { return m }
    return nil
  }

  var toolResult: ToolResultMessage? {
    if case let .toolResult(m) = self { return m }
    return nil
  }
}
