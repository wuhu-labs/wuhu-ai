import Foundation
import Fetch
import FetchSSE
import HTTPTypes

public struct OpenAIResponsesProvider: Sendable {
  private let fetch: FetchClient

  public init(fetch: FetchClient) {
    self.fetch = fetch
  }

  public func stream(model: Model, context: Context, options: RequestOptions = .init()) async throws
    -> AsyncThrowingStream<AssistantMessageEvent, any Error>
  {
    guard model.provider == .openai else { throw WuhuAIError.unsupported("Expected provider openai") }

    let apiKey = try resolveAPIKey(options.apiKey, env: "OPENAI_API_KEY", provider: model.provider)

    let url = model.baseURL.appending(path: "responses")
    var headers = Headers()
    headers[.authorization] = "Bearer \(apiKey)"
    headers[.contentType] = "application/json"
    headers[.accept] = "text/event-stream"
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

    if let system = context.systemPrompt, !system.isEmpty {
      input.append([
        "role": "system",
        "content": system,
      ])
    }

    var msgIndex = 0
    for message in context.messages {
      switch message {
      case let .user(m):
        let text = m.content.compactMap { block -> String? in
          if case let .text(part) = block { return part.text }
          return nil
        }.joined(separator: "\n")

        let imageContentBlocks: [[String: Any]] = m.content.compactMap { block in
          guard case let .image(img) = block else { return nil }
          return [
            "type": "input_image",
            "detail": "auto",
            "image_url": "data:\(img.mimeType);base64,\(img.data)",
          ]
        }

        if imageContentBlocks.isEmpty {
          if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
          input.append([
            "role": "user",
            "content": [
              [
                "type": "input_text",
                "text": text,
              ],
            ],
          ])
        } else {
          var contentBlocks: [[String: Any]] = []
          if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contentBlocks.append([
              "type": "input_text",
              "text": text,
            ])
          }
          contentBlocks.append(contentsOf: imageContentBlocks)
          input.append([
            "role": "user",
            "content": contentBlocks,
          ])
        }

      case let .assistant(m):
        for block in m.content {
          switch block {
          case let .text(part):
            let id = normalizeOpenAIItemId(part.signature ?? "msg_\(msgIndex)")
            input.append([
              "type": "message",
              "role": "assistant",
              "content": [
                [
                  "type": "output_text",
                  "text": part.text,
                  "annotations": [],
                ],
              ],
              "status": "completed",
              "id": id,
            ])
            msgIndex += 1

          case let .toolCall(call):
            let (callId, itemId) = splitToolCallId(call.id)
            var obj: [String: Any] = [
              "type": "function_call",
              "call_id": callId,
              "name": call.name,
              "arguments": jsonString(call.arguments),
            ]
            if let itemId {
              obj["id"] = itemId
            }
            input.append(obj)

          case let .reasoning(r):
            var obj: [String: Any] = [
              "type": "reasoning",
              "id": r.id,
              "summary": r.summary.map { $0.toAny() },
            ]
            if let encrypted = r.encryptedContent {
              obj["encrypted_content"] = encrypted
            }
            input.append(obj)

          case .image:
            continue
          }
        }

      case let .toolResult(m):
        let outputText = m.content.compactMap { block -> String? in
          if case let .text(part) = block { return part.text }
          return nil
        }.joined(separator: "\n")

        let imageContentBlocks: [[String: Any]] = m.content.compactMap { block in
          guard case let .image(img) = block else { return nil }
          return [
            "type": "input_image",
            "detail": "auto",
            "image_url": "data:\(img.mimeType);base64,\(img.data)",
          ]
        }

        let (callId, _) = splitToolCallId(m.toolCallId)

        let effectiveOutput: String = if outputText.isEmpty {
          imageContentBlocks.isEmpty ? "(no output)" : "(see attached image)"
        } else {
          outputText
        }

        input.append([
          "type": "function_call_output",
          "call_id": callId,
          "output": effectiveOutput,
        ])

        if !imageContentBlocks.isEmpty {
          var followUpContent: [[String: Any]] = [
            [
              "type": "input_text",
              "text": "Attached image(s) from tool result:",
            ],
          ]
          followUpContent.append(contentsOf: imageContentBlocks)
          input.append([
            "role": "user",
            "content": followUpContent,
          ])
        }
      }
    }

    var body: [String: Any] = [
      "model": model.id,
      "input": input,
      "stream": true,
      "store": envBool("PIAI_OPENAI_STORE") ?? false,
    ]

    if let tools = context.tools, !tools.isEmpty {
      body["tools"] = tools.map { tool in
        [
          "type": "function",
          "name": tool.name,
          "description": tool.description,
          "parameters": tool.parameters.toAny(),
          "strict": false,
        ] as [String: Any]
      }
    }

    if let temperature = options.temperature {
      body["temperature"] = temperature
    }
    if let maxTokens = options.maxTokens {
      body["max_output_tokens"] = maxTokens
    }
    if let sessionId = options.sessionId {
      body["prompt_cache_key"] = sessionId
    }

    if let effort = options.reasoningEffort {
      let clamped = clampReasoningEffort(modelId: model.id, effort: effort)
      body["reasoning"] = [
        "effort": clamped.rawValue,
      ]
      body["include"] = ["reasoning.encrypted_content"]
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

        var currentTextIndex: Int?
        var currentToolCallIndex: Int?
        var currentToolCallId: String?
        var currentToolCallName: String?
        var currentToolCallArgumentsBuffer = ""
        var reasoningIndexById: [String: Int] = [:]

        do {
          for try await message in sse {
            guard let dict = try parseJSON(message.data) else { continue }
            guard let type = dict["type"] as? String else { continue }

            switch type {
            case "response.output_item.added":
              guard let item = dict["item"] as? [String: Any],
                    let itemType = item["type"] as? String
              else { continue }

              if itemType == "message" {
                let id = item["id"] as? String
                output.content.append(.text(.init(text: "", signature: id)))
                currentTextIndex = output.content.count - 1
                currentToolCallIndex = nil
                currentToolCallId = nil
                currentToolCallName = nil
                currentToolCallArgumentsBuffer = ""
              } else if itemType == "function_call" {
                let callId = item["call_id"] as? String ?? UUID().uuidString
                let itemId = item["id"] as? String
                let name = item["name"] as? String ?? "tool"

                let fullId = itemId.map { "\(callId)|\($0)" } ?? callId
                output.content.append(.toolCall(.init(id: fullId, name: name, arguments: .object([:]))))
                currentToolCallIndex = output.content.count - 1
                currentToolCallId = fullId
                currentToolCallName = name
                currentToolCallArgumentsBuffer = item["arguments"] as? String ?? ""
                currentTextIndex = nil
              } else if itemType == "reasoning" {
                let id = item["id"] as? String ?? UUID().uuidString
                let encrypted = item["encrypted_content"] as? String
                let summaryAny = item["summary"] as? [Any] ?? []
                let summary = (try? summaryAny.map(JSONValue.fromAny)) ?? []
                output.content.append(.reasoning(.init(id: id, encryptedContent: encrypted, summary: summary)))
                reasoningIndexById[id] = output.content.count - 1
                currentTextIndex = nil
                currentToolCallIndex = nil
                currentToolCallId = nil
                currentToolCallName = nil
                currentToolCallArgumentsBuffer = ""
              }

            case "response.output_text.delta":
              guard let delta = dict["delta"] as? String else { continue }
              if let idx = currentTextIndex,
                 idx >= 0,
                 idx < output.content.count,
                 case var .text(part) = output.content[idx]
              {
                part.text += delta
                output.content[idx] = .text(part)
              } else {
                applyTextDelta(delta, to: &output)
              }
              continuation.yield(.textDelta(delta: delta, partial: output))

            case "response.function_call_arguments.delta":
              guard let delta = dict["delta"] as? String else { continue }
              guard currentToolCallIndex != nil else { continue }
              currentToolCallArgumentsBuffer += delta

            case "response.function_call_arguments.done":
              if let arguments = dict["arguments"] as? String, !arguments.isEmpty {
                currentToolCallArgumentsBuffer = arguments
              }

            case "response.output_item.done":
              guard let item = dict["item"] as? [String: Any],
                    let itemType = item["type"] as? String
              else { continue }

              if itemType == "message" {
                currentTextIndex = nil
              } else if itemType == "function_call" {
                let argsText = (currentToolCallArgumentsBuffer.isEmpty ? (item["arguments"] as? String) : currentToolCallArgumentsBuffer) ?? ""
                if let idx = currentToolCallIndex,
                   idx >= 0,
                   idx < output.content.count,
                   let id = currentToolCallId,
                   let name = currentToolCallName
                {
                  let args = parseJSONValueLenient(argsText) ?? .object([:])
                  output.content[idx] = .toolCall(.init(id: id, name: name, arguments: args))
                }
                currentToolCallIndex = nil
                currentToolCallId = nil
                currentToolCallName = nil
                currentToolCallArgumentsBuffer = ""
              } else if itemType == "reasoning" {
                let id = item["id"] as? String ?? UUID().uuidString
                let encrypted = item["encrypted_content"] as? String
                let summaryAny = item["summary"] as? [Any] ?? []
                let summary = (try? summaryAny.map(JSONValue.fromAny)) ?? []

                if let idx = reasoningIndexById[id],
                   idx >= 0,
                   idx < output.content.count,
                   case let .reasoning(existing) = output.content[idx]
                {
                  output.content[idx] = .reasoning(.init(
                    id: existing.id,
                    encryptedContent: encrypted ?? existing.encryptedContent,
                    summary: summary.isEmpty ? existing.summary : summary,
                  ))
                } else {
                  output.content.append(.reasoning(.init(id: id, encryptedContent: encrypted, summary: summary)))
                  reasoningIndexById[id] = output.content.count - 1
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
              if let response = dict["response"] as? [String: Any],
                 let status = response["status"] as? String
              {
                output.stopReason = mapOpenAIResponsesStopReason(status)
              }
              if output.content.contains(where: { if case .toolCall = $0 { true } else { false } }) {
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
          continuation.yield(.done(message: output))
          continuation.finish()
        } catch {
          output.stopReason = .error
          output.errorMessage = String(describing: error)
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

private func splitToolCallId(_ id: String) -> (callId: String, itemId: String?) {
  let parts = id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
  if parts.count == 2 {
    return (String(parts[0]), String(parts[1]))
  }
  return (id, nil)
}

private func jsonString(_ value: JSONValue) -> String {
  if case let .string(s) = value { return s }
  if let data = try? JSONSerialization.data(withJSONObject: value.toAny(), options: .sortedKeys),
     let text = String(data: data, encoding: .utf8)
  {
    return text
  }
  return "{}"
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

private func normalizeOpenAIItemId(_ raw: String) -> String {
  if raw.count <= 64 { return raw }
  return String(raw.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}

private func mapOpenAIResponsesStopReason(_ status: String) -> StopReason {
  switch status {
  case "completed":
    .stop
  case "incomplete":
    .length
  case "failed", "cancelled":
    .error
  case "in_progress", "queued":
    .stop
  default:
    .stop
  }
}
