import Foundation
import JSONValue

// MARK: - Responses Stream Parser

/// Parse OpenAI Responses SSE stream into AssistantMessageEvent domain events.
func parseResponsesStream(
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
      var completedStatus: String?

      func partial() -> AssistantMessage {
        AssistantMessage(content: content, phase: phase)
      }

      continuation.yield(.start(partial()))

      var currentTextIndex: Int?
      var currentToolCallIndex: Int?
      var currentToolCallID: String?
      var currentToolCallName: String?
      var currentToolCallArguments: String = ""
      var reasoningIndexByID: [String: Int] = [:]

      do {
        for try await sseEvent in sse {
          guard let dict = parseJSON(sseEvent.data) else { continue }
          guard let type = dict["type"] as? String else { continue }

          switch type {
          case "response.output_item.added":
            guard let item = dict["item"] as? [String: Any],
                  let itemType = item["type"] as? String
            else { continue }

            if itemType == "message" {
              content.append(.text(TextContent(text: "")))
              currentTextIndex = content.count - 1
              currentToolCallIndex = nil
              currentToolCallID = nil
              currentToolCallName = nil
              currentToolCallArguments = ""

              // Check for phase
              if let phaseStr = item["phase"] as? String {
                phase = AssistantMessagePhase(rawValue: phaseStr)
              }

              continuation.yield(.textStart(
                contentIndex: currentTextIndex!,
                partial: partial(),
              ))

            } else if itemType == "function_call" {
              let callID = item["call_id"] as? String ?? UUID().uuidString
              let itemID = item["id"] as? String
              let name = item["name"] as? String ?? "tool"

              let fullID = itemID.map { "\(callID)|\($0)" } ?? callID
              content.append(.toolCall(ToolCall(
                id: fullID,
                name: name,
                arguments: .object([:]),
              )))
              currentToolCallIndex = content.count - 1
              currentToolCallID = fullID
              currentToolCallName = name
              currentToolCallArguments = item["arguments"] as? String ?? ""
              currentTextIndex = nil

              continuation.yield(.toolCallStart(
                contentIndex: currentToolCallIndex!,
                partial: partial(),
              ))

            } else if itemType == "reasoning" {
              let id = item["id"] as? String ?? UUID().uuidString
              let encrypted = item["encrypted_content"] as? String
              let summaryAny = item["summary"] as? [Any] ?? []
              let summaryText = summaryAny.compactMap { part -> String? in
                guard let p = part as? [String: Any],
                      p["type"] as? String == "summary_text",
                      let text = p["text"] as? String
                else { return nil }
                return text
              }.joined(separator: "\n")

              content.append(.reasoning(.encrypted(EncryptedReasoningContent(
                providerID: providerID,
                model: model,
                summary: summaryText.isEmpty ? nil : summaryText,
                opaque: encrypted ?? "",
                id: id,
              ))))
              let idx = content.count - 1
              reasoningIndexByID[id] = idx
              currentTextIndex = nil
              currentToolCallIndex = nil
              currentToolCallID = nil
              currentToolCallName = nil
              currentToolCallArguments = ""

              continuation.yield(.reasoningStart(
                contentIndex: idx,
                partial: partial(),
              ))

              if !summaryText.isEmpty {
                continuation.yield(.reasoningEnd(
                  contentIndex: idx,
                  text: summaryText,
                  partial: partial(),
                ))
              }
            }

          case "response.output_text.delta":
            guard let delta = dict["delta"] as? String else { continue }
            if let idx = currentTextIndex, idx < content.count,
               case var .text(part) = content[idx]
            {
              part.text += delta
              content[idx] = .text(part)
            } else {
              content.append(.text(TextContent(text: delta)))
              currentTextIndex = content.count - 1
              continuation.yield(.textStart(
                contentIndex: currentTextIndex!,
                partial: partial(),
              ))
            }
            continuation.yield(.textDelta(
              contentIndex: currentTextIndex!,
              delta: delta,
              partial: partial(),
            ))

          case "response.function_call_arguments.delta":
            guard let delta = dict["delta"] as? String else { continue }
            guard currentToolCallIndex != nil else { continue }
            currentToolCallArguments += delta
            continuation.yield(.toolCallDelta(
              contentIndex: currentToolCallIndex!,
              delta: delta,
              partial: partial(),
            ))

          case "response.function_call_arguments.done":
            if let arguments = dict["arguments"] as? String, !arguments.isEmpty {
              currentToolCallArguments = arguments
            }

          case "response.output_item.done":
            guard let item = dict["item"] as? [String: Any],
                  let itemType = item["type"] as? String
            else { continue }

            if itemType == "message" {
              if let idx = currentTextIndex, idx < content.count,
                 case let .text(part) = content[idx]
              {
                continuation.yield(.textEnd(
                  contentIndex: idx,
                  text: part.text,
                  partial: partial(),
                ))
              }
              currentTextIndex = nil

              // Check for phase
              if let phaseStr = item["phase"] as? String {
                phase = AssistantMessagePhase(rawValue: phaseStr)
              }

            } else if itemType == "function_call" {
              let argsText = currentToolCallArguments.isEmpty
                ? (item["arguments"] as? String ?? "")
                : currentToolCallArguments

              if let idx = currentToolCallIndex, idx < content.count,
                 let id = currentToolCallID, let name = currentToolCallName
              {
                let args = JSONValue.parse(argsText) ?? .object([:])
                let toolCall = ToolCall(id: id, name: name, arguments: args)
                content[idx] = .toolCall(toolCall)
                continuation.yield(.toolCallEnd(
                  contentIndex: idx,
                  toolCall: toolCall,
                  partial: partial(),
                ))
              }
              currentToolCallIndex = nil
              currentToolCallID = nil
              currentToolCallName = nil
              currentToolCallArguments = ""

            } else if itemType == "reasoning" {
              let id = item["id"] as? String ?? UUID().uuidString
              let encrypted = item["encrypted_content"] as? String
              let summaryAny = item["summary"] as? [Any] ?? []
              let summaryText = summaryAny.compactMap { part -> String? in
                guard let p = part as? [String: Any],
                      p["type"] as? String == "summary_text",
                      let text = p["text"] as? String
                else { return nil }
                return text
              }.joined(separator: "\n")

              if let idx = reasoningIndexByID[id], idx < content.count {
                content[idx] = .reasoning(.encrypted(EncryptedReasoningContent(
                  providerID: providerID,
                  model: model,
                  summary: summaryText.isEmpty ? nil : summaryText,
                  opaque: encrypted ?? "",
                  id: id,
                )))
                if !summaryText.isEmpty {
                  continuation.yield(.reasoningEnd(
                    contentIndex: idx,
                    text: summaryText,
                    partial: partial(),
                  ))
                }
              }
            }

          case "response.completed":
            if let response = dict["response"] as? [String: Any] {
              if let usageDict = response["usage"] as? [String: Any] {
                let input = intValue(usageDict["input_tokens"]) ?? 0
                let outputTokens = intValue(usageDict["output_tokens"]) ?? 0
                let total = intValue(usageDict["total_tokens"]) ?? (input + outputTokens)
                let reasoning = intValue(usageDict["reasoning_tokens"]) ?? 0
                let cacheRead = intValue(usageDict["cached_input_tokens"]) ?? 0

                usage = Usage(
                  inputTokens: input,
                  outputTokens: outputTokens,
                  cacheReadTokens: cacheRead,
                  cacheWriteTokens: 0,
                  reasoningTokens: reasoning,
                  totalTokens: total,
                )
              }
              completedStatus = response["status"] as? String

              // Use incomplete_details.reason for stop reason
              if let incomplete = response["incomplete_details"] as? [String: Any],
                 let reason = incomplete["reason"] as? String
              {
                stopReason = mapIncompleteReason(reason)
              } else if completedStatus == "completed" {
                stopReason = .stop
              }
            }

          case "response.failed", "response.cancelled":
            // These are stream-level failures — throw them.
            let status = (dict["response"] as? [String: Any])?["status"] as? String ?? type
            throw ResponsesStreamError.failed(status: status)

          default:
            break
          }
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

// MARK: - Responses Error

enum ResponsesStreamError: Error {
  case failed(status: String)
}

// MARK: - Codex Stream Parser

/// Parse OpenAI Codex (Responses variant) SSE stream into domain events.
/// Codex uses the same SSE structure as Responses with minor differences.
func parseCodexStream(
  _ sse: AsyncThrowingStream<SSEEvent, any Error>,
  providerID: String,
  model: String,
) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
  // Codex uses the same SSE protocol as Responses.
  parseResponsesStream(sse, providerID: providerID, model: model)
}

// MARK: - Helpers

private func parseJSON(_ text: String) -> [String: Any]? {
  guard let data = text.data(using: .utf8),
        let value = try? JSONDecoder().decode(JSONValue.self, from: data),
        case let .object(obj) = value else { return nil }
  return obj.mapValues { $0.toAny() }
}

private func mapIncompleteReason(_ reason: String) -> StopReason {
  switch reason {
  case "max_output_tokens": return .maxTokens
  case "content_filter": return .refusal
  default: return .stop
  }
}

/// Extract an Int from a JSONDecoder-produced value (which uses Double for all numbers).
private func intValue(_ any: Any?) -> Int? {
  guard let any else { return nil }
  if let i = any as? Int { return i }
  if let d = any as? Double { return Int(exactly: d) }
  return nil
}
