import Foundation
import Fetch
import FetchSSE
import HTTPTypes

public struct AnthropicMessagesProvider: Sendable {
  private let fetch: FetchClient
  private let promptCachingBetaFeature = "prompt-caching-2024-07-31"
  private let interleavedThinkingBetaFeature = "interleaved-thinking-2025-05-14"

  public init(fetch: FetchClient) {
    self.fetch = fetch
  }

  public func stream(model: Model, context: Context, options: RequestOptions = .init()) async throws
    -> AsyncThrowingStream<AssistantMessageEvent, any Error>
  {
    guard model.provider == .anthropic else { throw WuhuAIError.unsupported("Expected provider anthropic") }

    let apiKey = try resolveAPIKey(options.apiKey, env: "ANTHROPIC_API_KEY", provider: model.provider)
    let url = model.baseURL.appending(path: "messages")
    let thinking = try resolveAnthropicThinkingOptions(model: model, options: options)

    var headers = Headers()
    headers[.contentType] = "application/json"
    headers[.accept] = "text/event-stream"
    setHeader(apiKey, for: "x-api-key", in: &headers)
    setHeader("2023-06-01", for: "anthropic-version", in: &headers)
    for (k, v) in options.headers {
      setHeader(v, for: k, in: &headers)
    }
    if let caching = options.anthropicPromptCaching,
       caching.sendBetaHeader
    {
      let existing = getHeaderValue(headers, name: "anthropic-beta")
      let merged = mergeCSVHeader(existing, adding: promptCachingBetaFeature)
      setHeader(merged, for: "anthropic-beta", in: &headers)
    }
    if let thinking,
       shouldSendInterleavedThinkingBeta(for: model.id, thinking: thinking)
    {
      let existing = getHeaderValue(headers, name: "anthropic-beta")
      let merged = mergeCSVHeader(existing, adding: interleavedThinkingBetaFeature)
      setHeader(merged, for: "anthropic-beta", in: &headers)
    }

    let request = try makeJSONRequest(
      url: url,
      headers: headers,
      bodyJSONObject: buildBody(model: model, context: context, options: options, thinking: thinking)
    )

    let response = try await validatedResponse(for: request, using: self.fetch)
    return mapAnthropicSSE(response.sse(), provider: model.provider, modelId: model.id)
  }

  private func buildBody(
    model: Model,
    context: Context,
    options: RequestOptions,
    thinking: AnthropicThinkingOptions?
  ) -> [String: Any] {
    var params: [[String: Any]] = []

    var i = 0
    while i < context.messages.count {
      let message = context.messages[i]

      switch message {
      case let .user(m):
        let textBlocks: [[String: Any]] = m.content.compactMap { block in
          guard case let .text(part) = block else { return nil }
          guard !part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
          return [
            "type": "text",
            "text": part.text,
          ]
        }

        let imageBlocks: [[String: Any]] = m.content.compactMap { block in
          guard case let .image(img) = block else { return nil }
          return [
            "type": "image",
            "source": [
              "type": "base64",
              "media_type": img.mimeType,
              "data": img.data,
            ],
          ]
        }

        let contentBlocks: [[String: Any]] = if imageBlocks.isEmpty {
          textBlocks.isEmpty ? [] : textBlocks
        } else {
          if textBlocks.isEmpty {
            [[
              "type": "text",
              "text": "(see attached image)",
            ]] + imageBlocks
          } else {
            textBlocks + imageBlocks
          }
        }

        if !contentBlocks.isEmpty {
          params.append([
            "role": "user",
            "content": contentBlocks,
          ])
        }
        i += 1

      case let .assistant(m):
        let blocks: [[String: Any]] = m.content.compactMap { block in
          switch block {
          case let .text(part):
            guard !part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return [
              "type": "text",
              "text": part.text,
            ]

          case let .toolCall(call):
            return [
              "type": "tool_use",
              "id": call.id,
              "name": call.name,
              "input": call.arguments.toAny(),
            ]

          case let .reasoning(reasoning):
            return makeAnthropicReasoningBlock(reasoning)

          case .image:
            return nil
          }
        }
        if !blocks.isEmpty {
          params.append([
            "role": "assistant",
            "content": blocks,
          ])
        }
        i += 1

      case .toolResult:
        var toolResults: [[String: Any]] = []
        while i < context.messages.count {
          guard case let .toolResult(m) = context.messages[i] else { break }

          let text = m.content.compactMap { block -> String? in
            if case let .text(part) = block { return part.text }
            return nil
          }.joined(separator: "\n")

          let imageBlocks: [[String: Any]] = m.content.compactMap { block in
            guard case let .image(img) = block else { return nil }
            return [
              "type": "image",
              "source": [
                "type": "base64",
                "media_type": img.mimeType,
                "data": img.data,
              ],
            ]
          }

          if imageBlocks.isEmpty {
            toolResults.append([
              "type": "tool_result",
              "tool_use_id": m.toolCallId,
              "content": text.isEmpty ? "(no output)" : text,
              "is_error": m.isError,
            ])
          } else {
            var contentBlocks: [[String: Any]] = []
            if !text.isEmpty {
              contentBlocks.append([
                "type": "text",
                "text": text,
              ])
            }
            contentBlocks.append(contentsOf: imageBlocks)
            toolResults.append([
              "type": "tool_result",
              "tool_use_id": m.toolCallId,
              "content": contentBlocks,
              "is_error": m.isError,
            ])
          }
          i += 1
        }

        if !toolResults.isEmpty {
          params.append([
            "role": "user",
            "content": toolResults,
          ])
        }
      }
    }

    var body: [String: Any] = [
      "model": model.id,
      "stream": true,
      "messages": params,
      "max_tokens": options.maxTokens ?? 16384,
    ]

    if let temperature = options.temperature {
      body["temperature"] = temperature
    }

    if let thinking {
      body["thinking"] = anthropicThinkingObject(from: thinking)
      if let adaptiveEffort = resolveAnthropicAdaptiveEffort(thinking: thinking) {
        body["output_config"] = [
          "effort": adaptiveEffort.rawValue,
        ]
      }
    }

    if let caching = options.anthropicPromptCaching {
      switch caching.mode {
      case .automatic:
        body["cache_control"] = ["type": "ephemeral"]
        if let system = context.systemPrompt, !system.isEmpty {
          body["system"] = system
        }

      case .explicitBreakpoints:
        if let system = context.systemPrompt, !system.isEmpty {
          body["system"] = [
            [
              "type": "text",
              "text": system,
              "cache_control": ["type": "ephemeral"],
            ],
          ]
        }
        if var messages = body["messages"] as? [[String: Any]] {
          applyExplicitPromptCachingToLastUserTurn(messages: &messages)
          body["messages"] = messages
        }
      }
    } else if let system = context.systemPrompt, !system.isEmpty {
      body["system"] = system
    }

    if let tools = context.tools, !tools.isEmpty {
      body["tools"] = tools.map { tool in
        [
          "name": tool.name,
          "description": tool.description,
          "input_schema": tool.parameters.toAny(),
        ] as [String: Any]
      }
    }

    return body
  }

  private func resolveAnthropicThinkingOptions(
    model: Model,
    options: RequestOptions,
  ) throws -> AnthropicThinkingOptions? {
    if let thinking = options.anthropicThinking {
      if thinking.mode == .adaptive,
         !supportsAnthropicAdaptiveThinking(modelId: model.id)
      {
        throw WuhuAIError.unsupported(
          "Anthropic adaptive thinking requires Claude Opus 4.6 / Sonnet 4.6 or later compatible models"
        )
      }
      return thinking
    }

    guard let effort = options.reasoningEffort,
          supportsAnthropicAdaptiveThinking(modelId: model.id)
    else {
      return nil
    }

    return AnthropicThinkingOptions(
      mode: .adaptive,
      effort: effort,
      display: .summarized,
      interleaved: true,
    )
  }

  private func anthropicThinkingObject(from options: AnthropicThinkingOptions) -> [String: Any] {
    var object: [String: Any] = [
      "display": options.display.rawValue,
    ]

    switch options.mode {
    case .manual:
      object["type"] = "enabled"
      if let budgetTokens = options.budgetTokens {
        object["budget_tokens"] = budgetTokens
      }

    case .adaptive:
      object["type"] = "adaptive"
    }

    return object
  }

  private func resolveAnthropicAdaptiveEffort(thinking: AnthropicThinkingOptions) -> AnthropicAdaptiveReasoningEffort? {
    guard thinking.mode == .adaptive,
          let effort = thinking.effort
    else {
      return nil
    }
    return mapReasoningEffortToAnthropicAdaptive(effort)
  }

  private func makeAnthropicReasoningBlock(_ reasoning: ReasoningContent) -> [String: Any]? {
    if let redactedData = reasoning.redactedData {
      return [
        "type": "redacted_thinking",
        "data": redactedData,
      ]
    }

    guard let signature = reasoning.signature ?? reasoning.encryptedContent else {
      return nil
    }

    return [
      "type": "thinking",
      "thinking": reasoning.text ?? "",
      "signature": signature,
    ]
  }

  private func shouldSendInterleavedThinkingBeta(for modelId: String, thinking: AnthropicThinkingOptions) -> Bool {
    guard thinking.interleaved else { return false }

    switch thinking.mode {
    case .manual:
      return true
    case .adaptive:
      return !supportsAnthropicAdaptiveThinking(modelId: modelId)
    }
  }

  private func applyExplicitPromptCachingToLastUserTurn(messages: inout [[String: Any]]) {
    for idx in stride(from: messages.count - 1, through: 0, by: -1) {
      var message = messages[idx]
      guard let role = message["role"] as? String, role == "user" else { continue }

      if var blocks = message["content"] as? [[String: Any]] {
        guard !blocks.isEmpty else { continue }
        var last = blocks[blocks.count - 1]
        if last["cache_control"] == nil {
          last["cache_control"] = ["type": "ephemeral"]
          blocks[blocks.count - 1] = last
          message["content"] = blocks
          messages[idx] = message
        }
        return
      }

      if var contentAny = message["content"] as? [Any], !contentAny.isEmpty {
        if var last = contentAny[contentAny.count - 1] as? [String: Any], last["cache_control"] == nil {
          last["cache_control"] = ["type": "ephemeral"]
          contentAny[contentAny.count - 1] = last
          message["content"] = contentAny
          messages[idx] = message
        }
        return
      }
    }
  }

  private func mergeCSVHeader(_ existing: String?, adding feature: String) -> String {
    guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return feature
    }

    var items = existing
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

    if !items.contains(feature) {
      items.append(feature)
    }
    return items.joined(separator: ", ")
  }

  private func mapAnthropicSSE(
    _ sse: AsyncThrowingStream<SSEEvent, any Error>,
    provider: Provider,
    modelId: String,
  ) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        var output = AssistantMessage(provider: provider, model: modelId)
        continuation.yield(.start(partial: output))

        var currentTextIndex: Int?
        var currentToolCallIndex: Int?
        var currentReasoningIndex: Int?
        var currentToolCallArgumentsBuffer = ""
        var inputTokens = 0
        var outputTokens = 0

        do {
          for try await message in sse {
            let event = message.event
            guard let dict = try parseJSON(message.data) else { continue }

            switch event {
            case "message_start":
              if let msg = dict["message"] as? [String: Any],
                 let usage = msg["usage"] as? [String: Any]
              {
                inputTokens = (usage["input_tokens"] as? Int ?? 0)
                  + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                  + (usage["cache_read_input_tokens"] as? Int ?? 0)
              }

            case "content_block_start":
              if let block = dict["content_block"] as? [String: Any],
                 let type = block["type"] as? String
              {
                switch type {
                case "text":
                  output.content.append(.text(.init(text: "")))
                  currentTextIndex = output.content.count - 1
                  currentToolCallIndex = nil
                  currentReasoningIndex = nil
                  currentToolCallArgumentsBuffer = ""

                case "tool_use":
                  let id = block["id"] as? String ?? UUID().uuidString
                  let name = block["name"] as? String ?? "tool"
                  let inputAny = block["input"] ?? [:]
                  let args = (try? JSONValue.fromAny(inputAny)) ?? .object([:])
                  output.content.append(.toolCall(.init(id: id, name: name, arguments: args)))
                  currentToolCallIndex = output.content.count - 1
                  currentTextIndex = nil
                  currentReasoningIndex = nil
                  currentToolCallArgumentsBuffer = ""

                case "thinking":
                  output.content.append(.reasoning(.init(
                    id: "anthropic_reasoning_\(output.content.count)",
                    text: nonEmptyString(block["thinking"] as? String),
                    signature: nonEmptyString(block["signature"] as? String),
                  )))
                  currentReasoningIndex = output.content.count - 1
                  currentTextIndex = nil
                  currentToolCallIndex = nil
                  currentToolCallArgumentsBuffer = ""

                case "redacted_thinking":
                  output.content.append(.reasoning(.init(
                    id: "anthropic_reasoning_\(output.content.count)",
                    redactedData: block["data"] as? String,
                  )))
                  currentReasoningIndex = output.content.count - 1
                  currentTextIndex = nil
                  currentToolCallIndex = nil
                  currentToolCallArgumentsBuffer = ""

                default:
                  continue
                }
              }

            case "content_block_delta":
              if let delta = dict["delta"] as? [String: Any],
                 let deltaType = delta["type"] as? String
              {
                if deltaType == "text_delta", let text = delta["text"] as? String {
                  if let idx = currentTextIndex,
                     idx >= 0,
                     idx < output.content.count,
                     case var .text(part) = output.content[idx]
                  {
                    part.text += text
                    output.content[idx] = .text(part)
                  } else {
                    applyTextDelta(text, to: &output)
                  }
                  continuation.yield(.textDelta(delta: text, partial: output))
                } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                  currentToolCallArgumentsBuffer += partial
                } else if deltaType == "thinking_delta", let thinking = delta["thinking"] as? String {
                  if let idx = currentReasoningIndex,
                     idx >= 0,
                     idx < output.content.count,
                     case var .reasoning(reasoning) = output.content[idx]
                  {
                    reasoning.text = (reasoning.text ?? "") + thinking
                    output.content[idx] = .reasoning(reasoning)
                  }
                } else if deltaType == "signature_delta", let signature = delta["signature"] as? String {
                  if let idx = currentReasoningIndex,
                     idx >= 0,
                     idx < output.content.count,
                     case var .reasoning(reasoning) = output.content[idx]
                  {
                    reasoning.signature = (reasoning.signature ?? "") + signature
                    output.content[idx] = .reasoning(reasoning)
                  }
                }
              }

            case "content_block_stop":
              if let idx = currentToolCallIndex,
                 !currentToolCallArgumentsBuffer.isEmpty,
                 idx >= 0,
                 idx < output.content.count,
                 case let .toolCall(existing) = output.content[idx]
              {
                let args = parseJSONValueLenient(currentToolCallArgumentsBuffer) ?? existing.arguments
                output.content[idx] = .toolCall(.init(id: existing.id, name: existing.name, arguments: args))
              }
              currentTextIndex = nil
              currentToolCallIndex = nil
              currentReasoningIndex = nil
              currentToolCallArgumentsBuffer = ""

            case "message_delta":
              if let delta = dict["delta"] as? [String: Any],
                 let stopReason = delta["stop_reason"] as? String
              {
                output.stopReason = mapAnthropicStopReason(stopReason)
              }
              if let usage = dict["usage"] as? [String: Any] {
                outputTokens = usage["output_tokens"] as? Int ?? outputTokens
              }

            case "message_stop":
              if output.stopReason == .stop,
                 output.content.contains(where: { if case .toolCall = $0 { true } else { false } })
              {
                output.stopReason = .toolUse
              }

            default:
              continue
            }
          }

          if output.stopReason == .stop,
             output.content.contains(where: { if case .toolCall = $0 { true } else { false } })
          {
            output.stopReason = .toolUse
          }
          if inputTokens > 0 || outputTokens > 0 {
            output.usage = Usage(
              inputTokens: inputTokens,
              outputTokens: outputTokens,
              totalTokens: inputTokens + outputTokens,
            )
          }
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

private enum AnthropicAdaptiveReasoningEffort: String {
  case low
  case medium
  case high
  case max
}

private func supportsAnthropicAdaptiveThinking(modelId: String) -> Bool {
  let id = modelId.split(separator: "/").last.map(String.init) ?? modelId
  if id.localizedCaseInsensitiveContains("mythos") {
    return true
  }

  let patterns = ["claude-opus-4-", "claude-sonnet-4-"]
  for pattern in patterns {
    guard let range = id.range(of: pattern) else { continue }
    let suffix = id[range.upperBound...]
    let digits = suffix.prefix { $0.isNumber }
    if let minor = Int(digits), minor >= 6 {
      return true
    }
  }

  return false
}

private func mapReasoningEffortToAnthropicAdaptive(_ effort: ReasoningEffort) -> AnthropicAdaptiveReasoningEffort {
  switch effort {
  case .minimal:
    // Anthropic adaptive thinking has no `minimal` tier. We bias toward `medium`
    // as a best-effort bridge so reasoning remains meaningfully enabled.
    .medium
  case .low:
    .low
  case .medium:
    .medium
  case .high:
    .high
  case .xhigh:
    .max
  }
}

private func nonEmptyString(_ value: String?) -> String? {
  guard let value, !value.isEmpty else { return nil }
  return value
}

private func parseJSONValueLenient(_ text: String) -> JSONValue? {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  guard let data = trimmed.data(using: .utf8) else { return nil }
  do {
    let any = try JSONSerialization.jsonObject(with: data)
    return try JSONValue.fromAny(any)
  } catch {
    return nil
  }
}

private func mapAnthropicStopReason(_ reason: String) -> StopReason {
  switch reason {
  case "end_turn":
    .stop
  case "max_tokens":
    .length
  case "tool_use":
    .toolUse
  case "refusal", "sensitive":
    .error
  case "pause_turn", "stop_sequence":
    .stop
  default:
    .stop
  }
}
