import Foundation
import Fetch
import FetchSSE
import HTTPTypes

public struct OpenAICodexResponsesProvider: Sendable {
  private let fetch: FetchClient

  public init(fetch: FetchClient) {
    self.fetch = fetch
  }

  public func stream(model: Model, context: Context, options: RequestOptions = .init()) async throws
    -> AsyncThrowingStream<AssistantMessageEvent, any Error>
  {
    guard model.provider == .openaiCodex else { throw WuhuAIError.unsupported("Expected provider openai-codex") }

    let token = try resolveAPIKey(options.apiKey, env: "OPENAI_API_KEY", provider: model.provider)
    let accountId = try extractChatGPTAccountId(fromJWT: token)

    let url = model.baseURL.appending(path: "codex").appending(path: "responses")
    var headers = Headers()
    headers[.authorization] = "Bearer \(token)"
    headers[.accept] = "text/event-stream"
    headers[.contentType] = "application/json"
    setHeader(accountId, for: "chatgpt-account-id", in: &headers)
    setHeader("responses=experimental", for: "OpenAI-Beta", in: &headers)
    setHeader("pi", for: "originator", in: &headers)

    if let sessionId = options.sessionId, !sessionId.isEmpty {
      setHeader(sessionId, for: "conversation_id", in: &headers)
      setHeader(sessionId, for: "session_id", in: &headers)
    }

    for (k, v) in options.headers {
      setHeader(v, for: k, in: &headers)
    }

    let request = try makeJSONRequest(
      url: url,
      headers: headers,
      bodyJSONObject: buildBody(model: model, context: context, options: options)
    )

    let response = try await validatedResponse(for: request, using: self.fetch)
    return mapResponsesSSE(response.sse(), provider: model.provider, modelId: model.id)
  }

  private func buildBody(model: Model, context: Context, options: RequestOptions) -> [String: Any] {
    var input: [[String: Any]] = []
    for message in context.messages {
      switch message {
      case let .user(m):
        let text = m.content.compactMap { block -> String? in
          if case let .text(part) = block { return part.text }
          return nil
        }.joined(separator: "\n")
        input.append(["role": "user", "content": text])
      case let .assistant(m):
        let text = m.content.compactMap { block -> String? in
          if case let .text(part) = block { return part.text }
          return nil
        }.joined(separator: "\n")
        input.append(["role": "assistant", "content": text])
      case let .toolResult(m):
        let text = m.content.compactMap { block -> String? in
          if case let .text(part) = block { return part.text }
          return nil
        }.joined(separator: "\n")
        input.append(["role": "tool", "content": text])
      }
    }

    var body: [String: Any] = [
      "model": model.id,
      "stream": true,
      "store": envBool("PIAI_OPENAI_STORE") ?? false,
      "instructions": context.systemPrompt as Any,
      "input": input,
      "text": ["verbosity": "medium"],
      "include": ["reasoning.encrypted_content"],
    ]

    if let temperature = options.temperature {
      body["temperature"] = temperature
    }
    if let maxTokens = options.maxTokens {
      body["max_output_tokens"] = maxTokens
    }
    if let sessionId = options.sessionId, !sessionId.isEmpty {
      body["prompt_cache_key"] = sessionId
      body["prompt_cache_retention"] = "in-memory"
    }

    if let effort = options.reasoningEffort {
      let clamped = clampReasoningEffort(modelId: model.id, effort: effort)
      body["reasoning"] = [
        "effort": clamped.rawValue,
        "summary": "auto",
      ]
    }

    return body
  }

  private func mapResponsesSSE(
    _ sse: AsyncThrowingStream<SSEEvent, any Error>,
    provider: Provider,
    modelId: String,
  ) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        var output = AssistantMessage(provider: provider, model: modelId)
        continuation.yield(.start(partial: output))

        do {
          for try await message in sse {
            guard let dict = try parseJSON(message.data) else { continue }
            guard let type = dict["type"] as? String else { continue }

            switch type {
            case "response.output_text.delta":
              guard let delta = dict["delta"] as? String else { continue }
              applyTextDelta(delta, to: &output)
              continuation.yield(.textDelta(delta: delta, partial: output))

            case "response.output_item.done":
              if let item = dict["item"] as? [String: Any],
                 let content = item["content"] as? [[String: Any]]
              {
                let text = content
                  .filter { ($0["type"] as? String) == "output_text" }
                  .compactMap { $0["text"] as? String }
                  .joined()
                if !text.isEmpty {
                  output.content = [.text(.init(text: text))]
                }
              }

            case "response.completed":
              if let response = dict["response"] as? [String: Any],
                 let usage = response["usage"] as? [String: Any]
              {
                let input = usage["input_tokens"] as? Int ?? 0
                let outputTokens = usage["output_tokens"] as? Int ?? 0
                let total = usage["total_tokens"] as? Int ?? (input + outputTokens)
                output.usage = Usage(inputTokens: input, outputTokens: outputTokens, totalTokens: total)
              }

            case "response.failed":
              throw WuhuAIError.httpStatus(code: 500, body: message.data)

            default:
              continue
            }
          }

          output.stopReason = .stop
          continuation.yield(.done(message: output))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }
}

private func clampReasoningEffort(modelId: String, effort: ReasoningEffort) -> ReasoningEffort {
  let id = modelId.split(separator: "/").last.map(String.init) ?? modelId

  if id.hasPrefix("gpt-5.2") || id.hasPrefix("gpt-5.3"), effort == .minimal {
    return .low
  }
  if id == "gpt-5.1", effort == .xhigh {
    return .high
  }
  if id == "gpt-5.1-codex-mini" {
    return (effort == .high || effort == .xhigh) ? .high : .medium
  }

  if effort == .xhigh, !(id.hasPrefix("gpt-5.2") || id.hasPrefix("gpt-5.3")) {
    return .high
  }

  return effort
}

private func extractChatGPTAccountId(fromJWT token: String) throws -> String {
  let parts = token.split(separator: ".")
  guard parts.count == 3 else { throw WuhuAIError.decoding("Invalid JWT") }

  let payload = String(parts[1])
  guard let payloadData = base64URLDecode(payload) else { throw WuhuAIError.decoding("Invalid base64 payload") }

  let json = try JSONSerialization.jsonObject(with: payloadData)
  guard let dict = json as? [String: Any] else { throw WuhuAIError.decoding("JWT payload not object") }
  let claimKey = "https://api.openai.com/auth"
  guard let claim = dict[claimKey] as? [String: Any],
        let accountId = claim["chatgpt_account_id"] as? String,
        !accountId.isEmpty
  else {
    throw WuhuAIError.decoding("Missing chatgpt_account_id claim")
  }
  return accountId
}

private func base64URLDecode(_ base64url: String) -> Data? {
  var base64 = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  let padding = 4 - (base64.count % 4)
  if padding < 4 {
    base64 += String(repeating: "=", count: padding)
  }
  return Data(base64Encoded: base64)
}
