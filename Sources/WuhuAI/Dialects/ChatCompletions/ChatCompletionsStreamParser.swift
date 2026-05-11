import Foundation
import JSONValue

// MARK: - Chat Completions Stream Parser

/// Parse Chat Completions SSE stream into AssistantMessageEvent domain events.
func parseChatCompletionsStream(
  _ sse: AsyncThrowingStream<SSEEvent, any Error>,
  providerID: String,
  model: String,
) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
  AsyncThrowingStream { continuation in
    let task = Task {
      var content: [ContentBlock] = []
      var phase: AssistantMessagePhase?
      var stopReason: StopReason = .stop
      var usage: Usage?

      func partial() -> AssistantMessage {
        AssistantMessage(content: content, phase: phase)
      }

      continuation.yield(.start(partial()))

      var currentTextIndex: Int?
      var currentToolCallIndex: Int?
      var currentToolCallBuffer: (id: String, name: String, arguments: String)?
      var currentReasoningIndex: Int?

      do {
        for try await sseEvent in sse {
          guard let dict = parseChatJSON(sseEvent.data) else { continue }

          // "[DONE]" marker
          if sseEvent.data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            break
          }

          guard let choices = dict["choices"] as? [[String: Any]],
                let choice = choices.first
          else { continue }

          let finishReason = choice["finish_reason"] as? String

          // Check for usage in the choice-level or top-level
          if let usageDict = dict["usage"] as? [String: Any] {
            usage = parseUsage(from: usageDict)
          }

          if let delta = choice["delta"] as? [String: Any] {
            // Text delta
            if let text = delta["content"] as? String, !text.isEmpty {
              if let idx = currentTextIndex, idx < content.count,
                 case var .text(part) = content[idx]
              {
                part.text += text
                content[idx] = .text(part)
              } else {
                content.append(.text(TextContent(text: text)))
                currentTextIndex = content.count - 1
                currentToolCallIndex = nil
                currentReasoningIndex = nil
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

            // Reasoning delta
            if let reasoningText = delta["reasoning_content"] as? String, !reasoningText.isEmpty {
              if let idx = currentReasoningIndex, idx < content.count,
                 case let .reasoning(reasoningContent) = content[idx],
                 case let .unencrypted(existing) = reasoningContent
              {
                content[idx] = .reasoning(.unencrypted(existing + reasoningText))
              } else {
                content.append(.reasoning(.unencrypted(reasoningText)))
                currentReasoningIndex = content.count - 1
                currentTextIndex = nil
                currentToolCallIndex = nil
                continuation.yield(.reasoningStart(
                  contentIndex: currentReasoningIndex!,
                  partial: partial(),
                ))
              }
              continuation.yield(.reasoningDelta(
                contentIndex: currentReasoningIndex!,
                delta: reasoningText,
                partial: partial(),
              ))
            }

            // Reasoning details (MiniMax)
            if let reasoningDetails = delta["reasoning_details"] as? [[String: Any]] {
              for detail in reasoningDetails {
                if let text = detail["text"] as? String {
                  let signature = detail["signature"] as? String
                  if let idx = currentReasoningIndex, idx < content.count,
                     case let .reasoning(reasoningContent) = content[idx],
                     case var .encrypted(enc) = reasoningContent
                  {
                    enc.summary = (enc.summary ?? "") + text
                    if let sig = signature { enc.opaque = sig }
                    content[idx] = .reasoning(.encrypted(enc))
                  } else {
                    content.append(.reasoning(.encrypted(EncryptedReasoningContent(
                      providerID: "minimax",
                      model: model,
                      summary: text,
                      opaque: signature ?? "",
                    ))))
                    currentReasoningIndex = content.count - 1
                    currentTextIndex = nil
                    currentToolCallIndex = nil
                    continuation.yield(.reasoningStart(
                      contentIndex: currentReasoningIndex!,
                      partial: partial(),
                    ))
                  }
                  continuation.yield(.reasoningDelta(
                    contentIndex: currentReasoningIndex!,
                    delta: text,
                    partial: partial(),
                  ))
                }
              }
            }

            // Tool call delta
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
              for tc in toolCalls {
                let id = tc["id"] as? String
                let function = tc["function"] as? [String: Any]
                let name = function?["name"] as? String
                let arguments = function?["arguments"] as? String

                // Use index to track tool calls
                if let idx = id ?? name {
                  if currentToolCallBuffer == nil || currentToolCallBuffer?.id != idx {
                    // New tool call
                    let callID = id ?? UUID().uuidString
                    let callName = name ?? ""
                    currentToolCallBuffer = (callID, callName, arguments ?? "")
                    content.append(.toolCall(ToolCall(
                      id: callID,
                      name: callName,
                      arguments: .object([:]),
                    )))
                    currentToolCallIndex = content.count - 1
                    currentTextIndex = nil
                    currentReasoningIndex = nil
                    continuation.yield(.toolCallStart(
                      contentIndex: currentToolCallIndex!,
                      partial: partial(),
                    ))
                  } else if let args = arguments {
                    currentToolCallBuffer?.arguments += args
                    continuation.yield(.toolCallDelta(
                      contentIndex: currentToolCallIndex!,
                      delta: args,
                      partial: partial(),
                    ))
                  }
                }
              }
            }
          }

          // Handle finish
          if let reason = finishReason {
            // Finalize tool calls
            if let idx = currentToolCallIndex,
               let buffer = currentToolCallBuffer,
               idx < content.count,
               case .toolCall = content[idx]
            {
              let parsed = JSONValue.parse(buffer.arguments) ?? .object([:])
              content[idx] = .toolCall(ToolCall(
                id: buffer.id,
                name: buffer.name,
                arguments: parsed,
              ))
              continuation.yield(.toolCallEnd(
                contentIndex: idx,
                toolCall: ToolCall(id: buffer.id, name: buffer.name, arguments: parsed),
                partial: partial(),
              ))
              currentToolCallIndex = nil
              currentToolCallBuffer = nil
            }

            // Emit textEnd if we have an active text block
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

            // Emit reasoningEnd if we have an active reasoning block
            if let idx = currentReasoningIndex, idx < content.count,
               case let .reasoning(reasoningContent) = content[idx]
            {
              continuation.yield(.reasoningEnd(
                contentIndex: idx,
                text: reasoningContent.text ?? "",
                partial: partial(),
              ))
              currentReasoningIndex = nil
            }

            stopReason = mapChatCompletionsFinishReason(reason)
          }
        }

        if stopReason == .stop,
           content.contains(where: { if case .toolCall = $0 { true } else { false } })
        {
          stopReason = .stop
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

private func parseChatJSON(_ text: String) -> [String: Any]? {
  guard let data = text.data(using: .utf8) else { return nil }
  return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func parseUsage(from dict: [String: Any]) -> Usage {
  let input = dict["input_tokens"] as? Int ?? dict["prompt_tokens"] as? Int ?? 0
  let outputTokens = dict["output_tokens"] as? Int ?? dict["completion_tokens"] as? Int ?? 0
  let total = dict["total_tokens"] as? Int ?? (input + outputTokens)
  let cacheRead = dict["cache_read_input_tokens"] as? Int ?? 0
  let cacheWrite = dict["cache_creation_input_tokens"] as? Int ?? 0
  let reasoning = dict["reasoning_tokens"] as? Int
    ?? (dict["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
    ?? 0

  return Usage(
    inputTokens: input,
    outputTokens: outputTokens,
    cacheReadTokens: cacheRead,
    cacheWriteTokens: cacheWrite,
    reasoningTokens: reasoning,
    totalTokens: total,
  )
}

private func mapChatCompletionsFinishReason(_ reason: String) -> StopReason {
  switch reason {
  case "stop", "tool_calls", "function_call": return .stop
  case "length": return .maxTokens
  case "content_filter": return .refusal
  default: return .stop
  }
}

private extension Dictionary where Key == String, Value == Any {
  subscript(caseInsensitive key: String) -> Any? {
    if let value = self[key] { return value }
    let lower = key.lowercased()
    for (k, v) in self where k.lowercased() == lower { return v }
    return nil
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
