import Foundation
import JSONValue

// MARK: - Anthropic Stream Parser

/// Parse Anthropic Messages SSE stream into AssistantMessageEvent domain events.
func parseAnthropicStream(
  _ sse: AsyncThrowingStream<SSEEvent, any Error>,
  providerID: String,
  model: String,
) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
  AsyncThrowingStream { continuation in
    let task = Task {
      var content: [ContentBlock] = []
      var phase: AssistantMessagePhase?
      var stopReason: StopReason = .stop
      var inputTokens = 0
      var outputTokens = 0

      func partial() -> AssistantMessage {
        AssistantMessage(content: content, phase: phase)
      }

      continuation.yield(.start(partial()))

      var currentTextIndex: Int?
      var currentToolCallIndex: Int?
      var currentReasoningIndex: Int?
      var currentToolCallArgumentsBuffer = ""

      do {
        for try await sseEvent in sse {
          guard let dict = parseJSON(sseEvent.data) else { continue }

          let event = sseEvent.event

          switch event {
          case "message_start":
            if let msg = dict["message"] as? [String: Any],
               let usage = msg["usage"] as? [String: Any]
            {
              inputTokens = (intValue(usage["input_tokens"]) ?? 0)
                + (intValue(usage["cache_creation_input_tokens"]) ?? 0)
                + (intValue(usage["cache_read_input_tokens"]) ?? 0)
            }

          case "content_block_start":
            guard let block = dict["content_block"] as? [String: Any],
                  let type = block["type"] as? String
            else { continue }

            switch type {
            case "text":
              content.append(.text(TextContent(text: "")))
              currentTextIndex = content.count - 1
              currentToolCallIndex = nil
              currentReasoningIndex = nil
              currentToolCallArgumentsBuffer = ""
              continuation.yield(.textStart(
                contentIndex: currentTextIndex!,
                partial: partial(),
              ))

            case "tool_use":
              let id = block["id"] as? String ?? UUID().uuidString
              let name = block["name"] as? String ?? "tool"
              let inputAny = block["input"] as? [String: Any] ?? [:]
              let args = (try? JSONValue.fromAny(inputAny)) ?? .object([:])
              content.append(.toolCall(ToolCall(
                id: id,
                name: name,
                arguments: args,
              )))
              currentToolCallIndex = content.count - 1
              currentTextIndex = nil
              currentReasoningIndex = nil
              currentToolCallArgumentsBuffer = ""
              continuation.yield(.toolCallStart(
                contentIndex: currentToolCallIndex!,
                partial: partial(),
              ))

            case "thinking":
              let thinkingText = nonEmptyString(block["thinking"] as? String)
              let signature = nonEmptyString(block["signature"] as? String) ?? ""
              content.append(.reasoning(.encrypted(EncryptedReasoningContent(
                providerID: providerID,
                model: model,
                summary: thinkingText,
                opaque: signature,
              ))))
              currentReasoningIndex = content.count - 1
              currentTextIndex = nil
              currentToolCallIndex = nil
              currentToolCallArgumentsBuffer = ""
              continuation.yield(.reasoningStart(
                contentIndex: currentReasoningIndex!,
                partial: partial(),
              ))

            case "redacted_thinking":
              let data = block["data"] as? String ?? ""
              content.append(.reasoning(.encrypted(EncryptedReasoningContent(
                providerID: providerID,
                model: model,
                summary: nil,
                opaque: data,
                redacted: true,
              ))))
              currentReasoningIndex = content.count - 1
              currentTextIndex = nil
              currentToolCallIndex = nil
              currentToolCallArgumentsBuffer = ""
              continuation.yield(.reasoningStart(
                contentIndex: currentReasoningIndex!,
                partial: partial(),
              ))

            default:
              break
            }

          case "content_block_delta":
            guard let delta = dict["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String
            else { continue }

            switch deltaType {
            case "text_delta":
              if let text = delta["text"] as? String {
                if let idx = currentTextIndex, idx < content.count,
                   case var .text(part) = content[idx]
                {
                  part.text += text
                  content[idx] = .text(part)
                } else {
                  content.append(.text(TextContent(text: text)))
                  currentTextIndex = content.count - 1
                  continuation.yield(.textStart(
                    contentIndex: currentTextIndex!,
                    partial: partial(),
                  ))
                }
                continuation.yield(.textDelta(
                  contentIndex: currentTextIndex!,
                  delta: text,
                  partial: partial(),
                ))
              }

            case "input_json_delta":
              if let partialJSON = delta["partial_json"] as? String {
                currentToolCallArgumentsBuffer += partialJSON
                if let idx = currentToolCallIndex {
                  continuation.yield(.toolCallDelta(
                    contentIndex: idx,
                    delta: partialJSON,
                    partial: partial(),
                  ))
                }
              }

            case "thinking_delta":
              if let thinking = delta["thinking"] as? String {
                if let idx = currentReasoningIndex, idx < content.count,
                   case let .reasoning(reasoningContent) = content[idx],
                   case var .encrypted(enc) = reasoningContent
                {
                  enc.summary = (enc.summary ?? "") + thinking
                  content[idx] = .reasoning(.encrypted(enc))
                  continuation.yield(.reasoningDelta(
                    contentIndex: idx,
                    delta: thinking,
                    partial: partial(),
                  ))
                }
              }

            case "signature_delta":
              if let signature = delta["signature"] as? String {
                if let idx = currentReasoningIndex, idx < content.count,
                   case let .reasoning(reasoningContent) = content[idx],
                   case var .encrypted(enc) = reasoningContent
                {
                  enc.opaque += signature
                  content[idx] = .reasoning(.encrypted(enc))
                }
              }

            default:
              break
            }

          case "content_block_stop":
            // Finalize tool call arguments
            if let idx = currentToolCallIndex,
               !currentToolCallArgumentsBuffer.isEmpty,
               idx < content.count,
               case let .toolCall(existing) = content[idx]
            {
              let args = JSONValue.parse(currentToolCallArgumentsBuffer) ?? existing.arguments
              let toolCall = ToolCall(id: existing.id, name: existing.name, arguments: args)
              content[idx] = .toolCall(toolCall)
              continuation.yield(.toolCallEnd(
                contentIndex: idx,
                toolCall: toolCall,
                partial: partial(),
              ))
            }

            // Emit textEnd
            if let idx = currentTextIndex, idx < content.count,
               case let .text(part) = content[idx]
            {
              continuation.yield(.textEnd(
                contentIndex: idx,
                text: part.text,
                partial: partial(),
              ))
              currentTextIndex = nil
            }

            // Emit reasoningEnd
            if let idx = currentReasoningIndex, idx < content.count,
               case let .reasoning(reasoningContent) = content[idx]
            {
              let text = reasoningContent.text ?? ""
              continuation.yield(.reasoningEnd(
                contentIndex: idx,
                text: text,
                partial: partial(),
              ))
              currentReasoningIndex = nil
            }

            currentToolCallIndex = nil
            currentToolCallArgumentsBuffer = ""

          case "message_delta":
            if let delta = dict["delta"] as? [String: Any],
               let stopReasonStr = delta["stop_reason"] as? String
            {
              stopReason = mapAnthropicStopReason(stopReasonStr)
            }
            if let usage = dict["usage"] as? [String: Any] {
              outputTokens = intValue(usage["output_tokens"]) ?? outputTokens
            }

          case "message_stop":
            if stopReason == .stop,
               content.contains(where: { if case .toolCall = $0 { true } else { false } })
            {
              stopReason = .stop
            }

          default:
            break
          }
        }

        if stopReason == .stop,
           content.contains(where: { if case .toolCall = $0 { true } else { false } })
        {
          stopReason = .stop
        }

        let usage: Usage? = if inputTokens > 0 || outputTokens > 0 {
          Usage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            totalTokens: inputTokens + outputTokens,
          )
        } else {
          nil
        }

        continuation.yield(.done(partial(), AssistantMessageMetadata(stopReason: stopReason, usage: usage)))
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

// MARK: - Helpers

private func parseJSON(_ text: String) -> [String: Any]? {
  guard let data = text.data(using: .utf8),
        let value = try? JSONDecoder().decode(JSONValue.self, from: data),
        case let .object(obj) = value else { return nil }
  return obj.mapValues { $0.toAny() }
}

private func nonEmptyString(_ value: String?) -> String? {
  guard let value, !value.isEmpty else { return nil }
  return value
}

private func mapAnthropicStopReason(_ reason: String) -> StopReason {
  switch reason {
  case "end_turn", "stop_sequence", "tool_use", "pause_turn": return .stop
  case "max_tokens", "model_context_window_exceeded": return .maxTokens
  case "refusal": return .refusal
  default: return .stop
  }
}

private extension ReasoningContent {
  var text: String? {
    switch self {
    case let .unencrypted(text): return text
    case let .encrypted(enc): return enc.summary
    }
  }
}

/// Extract an Int from a JSONDecoder-produced value (which uses Double for all numbers).
private func intValue(_ any: Any?) -> Int? {
  guard let any else { return nil }
  if let i = any as? Int { return i }
  if let d = any as? Double { return Int(exactly: d) }
  return nil
}
