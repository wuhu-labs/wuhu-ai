import Foundation
import JSONValue

// MARK: - OpenAI GPT Endpoint

public struct OpenAIGPTEndpoint: ModelEndpoint {
  public let providerID = "openai"
  public let model: String
  public let dialect: Dialect = .responses
  public let baseURL: URL

  public var apiKey: String
  public var promptCacheKey: String?
  public var cacheRetention: CacheRetention

  public init(
    model: String,
    baseURL: URL = URL(string: "https://api.openai.com/v1")!,
    apiKey: String,
    promptCacheKey: String? = nil,
    cacheRetention: CacheRetention = .short,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.promptCacheKey = promptCacheKey
    self.cacheRetention = cacheRetention
  }

  public func modifyBody(_ body: inout [String: JSONValue], options: RequestOptions) {
    if let key = promptCacheKey {
      body["prompt_cache_key"] = .string(key)
    }
    if cacheRetention == .long {
      body["prompt_cache_retention"] = .string("24h")
    }
  }

  public func modifyHeaders(_ options: RequestOptions) -> [String: String] {
    ["authorization": "Bearer \(apiKey)"]
  }
}

// MARK: - OpenAI Codex Endpoint

public struct OpenAICodexEndpoint: ModelEndpoint {
  public let providerID = "openai-codex"
  public let model: String
  public let dialect: Dialect = .responses
  public let baseURL: URL

  public var jwt: String
  public var environment: String?
  public var chatgptAccountID: String?
  public var conversationID: String?

  public init(
    model: String,
    baseURL: URL = URL(string: "https://chatgpt.com/backend-api")!,
    jwt: String,
    environment: String? = nil,
    chatgptAccountID: String? = nil,
    conversationID: String? = nil,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.jwt = jwt
    self.environment = environment
    self.chatgptAccountID = chatgptAccountID
    self.conversationID = conversationID
  }

  public func modifyBody(_ body: inout [String: JSONValue], options: RequestOptions) {
    // Codex uses "instructions" field instead of system message.
    // The Responses RequestBuilder puts system prompt into the input.
    // For Codex, we use instructions — handled by the RequestBuilder via
    // a special key convention.
    if let env = environment {
      body["_codex_environment"] = .string(env)
    }
    body["text"] = .object([
      "verbosity": .string("medium"),
    ])
  }

  public func modifyHeaders(_ options: RequestOptions) -> [String: String] {
    var headers: [String: String] = [
      "authorization": "Bearer \(jwt)",
      "chatgpt-account-id": chatgptAccountID ?? "",
    ]
    if let conversationID {
      headers["conversation_id"] = conversationID
    }
    return headers
  }

  public func normalizeOutput(_ message: inout AssistantMessage) {
    // Codex responses may include commentary phase. Ensure it's preserved.
  }
}

// MARK: - Anthropic Endpoint

public struct AnthropicEndpoint: ModelEndpoint {
  public let providerID = "anthropic"
  public let model: String
  public let dialect: Dialect = .anthropic
  public let baseURL: URL

  public var apiKey: String
  public var cacheControlTTL: String?

  public init(
    model: String,
    baseURL: URL = URL(string: "https://api.anthropic.com/v1")!,
    apiKey: String,
    cacheControlTTL: String? = nil,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.cacheControlTTL = cacheControlTTL
  }

  public func modifyBody(_ body: inout [String: JSONValue], options: RequestOptions) {
    switch options.reasoning {
    case .none:
      break
    case .automatic:
      body["thinking"] = .object([
        "type": .string("adaptive"),
        "display": .string("summarized"),
      ])
    case .effort(let effort):
      body["thinking"] = .object([
        "type": .string("adaptive"),
        "display": .string("summarized"),
      ])
      body["output_config"] = .object([
        "effort": .string(mapAnthropicEffort(effort)),
      ])
    case .budget(let tokens):
      body["thinking"] = .object([
        "type": .string("enabled"),
        "budget_tokens": .number(Double(tokens)),
      ])
    }
    if let ttl = cacheControlTTL {
      body["cache_control"] = .object(["type": .string(ttl)])
    }
  }

  public func modifyHeaders(_ options: RequestOptions) -> [String: String] {
    [
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    ]
  }
}

private func mapAnthropicEffort(_ effort: String) -> String {
  switch effort.lowercased() {
  case "minimal": return "low"
  case "xhigh": return "max"
  default: return effort.lowercased()
  }
}

// MARK: - DeepSeek Chat Endpoint

public struct DeepSeekChatEndpoint: ModelEndpoint {
  public let providerID = "deepseek"
  public let model: String
  public let dialect: Dialect = .chatCompletions
  public let baseURL: URL

  public var apiKey: String
  public var thinkingEnabled: Bool = true

  public init(
    model: String,
    baseURL: URL = URL(string: "https://api.deepseek.com/v1")!,
    apiKey: String,
    thinkingEnabled: Bool = true,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.thinkingEnabled = thinkingEnabled
  }

  public func modifyBody(_ body: inout [String: JSONValue], options: RequestOptions) {
    switch options.reasoning {
    case .none:
      body["thinking"] = .object(["type": .string("disabled")])
    case .automatic:
      body["thinking"] = .object(["type": .string("enabled")])
    case .effort(let effort):
      body["thinking"] = .object(["type": .string("enabled")])
      body["reasoning_effort"] = .string(effort)
    case .budget:
      break
    }
  }

  public func modifyHeaders(_ options: RequestOptions) -> [String: String] {
    ["authorization": "Bearer \(apiKey)"]
  }
}

// MARK: - DeepSeek Anthropic Endpoint

public struct DeepSeekAnthropicEndpoint: ModelEndpoint {
  public let providerID = "deepseek"
  public let model: String
  public let dialect: Dialect = .anthropic
  public let baseURL: URL

  public var apiKey: String

  public init(
    model: String,
    baseURL: URL = URL(string: "https://api.deepseek.com/anthropic")!,
    apiKey: String,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.apiKey = apiKey
  }

  public func modifyBody(_ body: inout [String: JSONValue], options: RequestOptions) {
    switch options.reasoning {
    case .none:
      break
    case .automatic:
      body["thinking"] = .object(["type": .string("enabled")])
    case .effort(let effort):
      body["thinking"] = .object(["type": .string("enabled")])
      body["output_config"] = .object(["effort": .string(effort)])
    case .budget(let tokens):
      body["thinking"] = .object([
        "type": .string("enabled"),
        "budget_tokens": .number(Double(tokens)),
      ])
    }
  }

  public func modifyHeaders(_ options: RequestOptions) -> [String: String] {
    [
      "authorization": "Bearer \(apiKey)",
      "anthropic-version": "2023-06-01",
    ]
  }
}

// MARK: - Gemini Endpoint

public struct GeminiEndpoint: ModelEndpoint {
  public let providerID = "gemini"
  public let model: String
  public let dialect: Dialect = .gemini
  public let baseURL: URL

  public var apiKey: String

  public init(
    model: String,
    baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
    apiKey: String,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.apiKey = apiKey
  }

  public func modifyBody(_ body: inout [String: JSONValue], options: RequestOptions) {
    var thinkingConfig: [String: JSONValue] = [
      "includeThoughts": .bool(true),
    ]
    switch options.reasoning {
    case .none:
      thinkingConfig["thinkingBudget"] = .number(0)
    case .automatic:
      break
    case .effort(let effort):
      thinkingConfig["thinkingBudget"] = .number(Double(mapGeminiEffortToBudget(effort)))
    case .budget(let tokens):
      thinkingConfig["thinkingBudget"] = .number(Double(tokens))
    }
    var gc = body["generationConfig"]?.object ?? [:]
    gc["thinkingConfig"] = .object(thinkingConfig)
    body["generationConfig"] = .object(gc)
  }

  public func modifyHeaders(_ options: RequestOptions) -> [String: String] {
    ["x-goog-api-key": apiKey]
  }
}

private func mapGeminiEffortToBudget(_ effort: String) -> Int {
  switch effort.lowercased() {
  case "minimal": return 256
  case "low": return 512
  case "medium": return 1024
  case "high": return 2048
  case "xhigh": return 8192
  default: return 1024
  }
}

// MARK: - Kimi Endpoint

public struct KimiEndpoint: ModelEndpoint {
  public let providerID = "kimi"
  public let model: String
  public let dialect: Dialect = .chatCompletions
  public let baseURL: URL

  public var apiKey: String

  public init(
    model: String,
    baseURL: URL = URL(string: "https://api.moonshot.cn/v1")!,
    apiKey: String,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.apiKey = apiKey
  }

  public func modifyBody(_ body: inout [String: JSONValue], options: RequestOptions) {
    switch options.reasoning {
    case .none:
      body["reasoning"] = .object(["enabled": .bool(false)])
    case .automatic:
      body["reasoning"] = .object(["enabled": .bool(true)])
    case .effort:
      body["reasoning"] = .object(["enabled": .bool(true)])
    case .budget:
      body["reasoning"] = .object(["enabled": .bool(true)])
    }
  }

  public func modifyHeaders(_ options: RequestOptions) -> [String: String] {
    ["authorization": "Bearer \(apiKey)"]
  }
}

// MARK: - Qwen Endpoint

public struct QwenEndpoint: ModelEndpoint {
  public let providerID = "qwen"
  public let model: String
  public let dialect: Dialect = .chatCompletions
  public let baseURL: URL

  public var apiKey: String
  public var preserveThinking: Bool = false

  public init(
    model: String,
    baseURL: URL = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!,
    apiKey: String,
    preserveThinking: Bool = false,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.preserveThinking = preserveThinking
  }

  public func modifyBody(_ body: inout [String: JSONValue], options: RequestOptions) {
    switch options.reasoning {
    case .none:
      body["enable_thinking"] = .bool(false)
    case .automatic:
      body["enable_thinking"] = .bool(true)
    case .effort:
      body["enable_thinking"] = .bool(true)
    case .budget:
      body["enable_thinking"] = .bool(true)
    }
    if preserveThinking {
      body["preserve_thinking"] = .bool(true)
    }
  }

  public func modifyHeaders(_ options: RequestOptions) -> [String: String] {
    ["authorization": "Bearer \(apiKey)"]
  }
}

// MARK: - MiniMax Endpoint

public struct MiniMaxEndpoint: ModelEndpoint {
  public let providerID = "minimax"
  public let model: String
  public let dialect: Dialect = .chatCompletions
  public let baseURL: URL

  public var apiKey: String
  public var reasoningSplit: Bool = true

  public init(
    model: String,
    baseURL: URL = URL(string: "https://api.minimax.chat/v1")!,
    apiKey: String,
    reasoningSplit: Bool = true,
  ) {
    self.model = model
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.reasoningSplit = reasoningSplit
  }

  public func modifyBody(_ body: inout [String: JSONValue], options: RequestOptions) {
    if reasoningSplit {
      body["reasoning_split"] = .bool(true)
    }
  }

  public func modifyHeaders(_ options: RequestOptions) -> [String: String] {
    ["authorization": "Bearer \(apiKey)"]
  }
}

// MARK: - ModelEndpoint Convenience Factories

extension ModelEndpoint {
  public static func openAIResponses(model: String, apiKey: String) -> OpenAIGPTEndpoint {
    OpenAIGPTEndpoint(model: model, apiKey: apiKey)
  }

  public static func openAICodex(
    model: String,
    jwt: String,
    environment: String? = nil,
  ) -> OpenAICodexEndpoint {
    OpenAICodexEndpoint(model: model, jwt: jwt, environment: environment)
  }

  public static func anthropic(model: String, apiKey: String) -> AnthropicEndpoint {
    AnthropicEndpoint(model: model, apiKey: apiKey)
  }

  public static func deepSeekChat(
    model: String,
    apiKey: String,
    thinkingEnabled: Bool = true,
  ) -> DeepSeekChatEndpoint {
    DeepSeekChatEndpoint(model: model, apiKey: apiKey, thinkingEnabled: thinkingEnabled)
  }

  public static func deepSeekAnthropic(model: String, apiKey: String) -> DeepSeekAnthropicEndpoint {
    DeepSeekAnthropicEndpoint(model: model, apiKey: apiKey)
  }

  public static func gemini(model: String, apiKey: String) -> GeminiEndpoint {
    GeminiEndpoint(model: model, apiKey: apiKey)
  }

  public static func kimi(model: String, apiKey: String) -> KimiEndpoint {
    KimiEndpoint(model: model, apiKey: apiKey)
  }

  public static func qwen(
    model: String,
    apiKey: String,
    preserveThinking: Bool = false,
  ) -> QwenEndpoint {
    QwenEndpoint(model: model, apiKey: apiKey, preserveThinking: preserveThinking)
  }

  public static func miniMax(
    model: String,
    apiKey: String,
    reasoningSplit: Bool = true,
  ) -> MiniMaxEndpoint {
    MiniMaxEndpoint(model: model, apiKey: apiKey, reasoningSplit: reasoningSplit)
  }
}
