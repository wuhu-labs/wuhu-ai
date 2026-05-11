import Foundation

// MARK: - Cross-Provider Replay Normalization

/// Transform messages for cross-provider replay.
///
/// - Parameters:
///   - messages: The conversation history to normalize.
///   - sourceProviderID: The providerID that generated the messages.
///   - targetEndpoint: The endpoint that will receive the messages.
func transformMessages(
  _ messages: inout [Message],
  from sourceProviderID: String,
  to targetEndpoint: any ModelEndpoint,
) {
  let sameProvider = targetEndpoint.isSameProvider(sourceProviderID)

  if !sameProvider {
    normalizeToolCallIDs(in: &messages, for: targetEndpoint.dialect)
  }

  for i in messages.indices {
    guard case var .assistant(msg) = messages[i] else { continue }

    if sameProvider {
      // Faithful replay: preserve opaques, passthrough.
    } else {
      // Cross-provider: convert reasoning to plain text, drop opaque.
      normalizeReasoningForCrossProvider(in: &msg)
    }

    // Normalize media blocks — drop if target doesn't support them.
    normalizeMediaForTarget(in: &msg, for: targetEndpoint.dialect)

    messages[i] = .assistant(msg)
  }
}

// MARK: - Tool Call ID Normalization

/// Normalize tool call IDs for cross-provider compatibility.
func normalizeToolCallIDs(
  in messages: inout [Message],
  for dialect: Dialect,
) {
  var idMap: [String: String] = [:]

  for i in messages.indices {
    switch messages[i] {
    case var .assistant(msg):
      var changed = false
      for j in msg.content.indices {
        if case var .toolCall(tc) = msg.content[j] {
          let normalized = normalizeToolCallID(tc.id, for: dialect)
          idMap[tc.id] = normalized
          if normalized != tc.id {
            tc.id = normalized
            msg.content[j] = .toolCall(tc)
            changed = true
          }
        }
      }
      if changed {
        messages[i] = .assistant(msg)
      }

    case var .toolResult(msg):
      if let normalized = idMap[msg.toolCallId] {
        msg.toolCallId = normalized
        messages[i] = .toolResult(msg)
      }

    default:
      break
    }
  }
}

/// Normalize a single tool call ID.
func normalizeToolCallID(_ id: String, for dialect: Dialect) -> String {
  // Extract call_id from compound "call_id|item_id" format
  let callID: String
  if let pipeIndex = id.firstIndex(of: "|") {
    callID = String(id[..<pipeIndex])
  } else {
    callID = id
  }

  // Sanitize to [a-zA-Z0-9_-]
  let sanitized = callID.unicodeScalars.map { scalar -> Character in
    if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
      return Character(scalar)
    }
    return "_"
  }
  let sanitizedStr = String(sanitized)

  // Truncate to dialect-appropriate limit
  let limit = dialect == .anthropic ? 64 : 40
  return String(sanitizedStr.prefix(limit))
}

// MARK: - Reasoning Normalization

/// Convert reasoning blocks to plain text for cross-provider replay.
func normalizeReasoningForCrossProvider(in message: inout AssistantMessage) {
  var newContent: [ContentBlock] = []

  for block in message.content {
    switch block {
    case let .reasoning(reasoning):
      switch reasoning {
      case let .unencrypted(text):
        newContent.append(.text(TextContent(text: text)))

      case let .encrypted(enc):
        // Has summary text → convert to plain text block
        if let summary = enc.summary {
          newContent.append(.text(TextContent(text: summary)))
        }
        // No summary but has opaque → drop (can't replay cross-provider)
      }

    default:
      newContent.append(block)
    }
  }

  message.content = newContent
}

// MARK: - Media Normalization

/// Drop media blocks if the target dialect doesn't support them.
func normalizeMediaForTarget(in message: inout AssistantMessage, for dialect: Dialect) {
  // Media output is out of scope per SPEC §8.
  // For now, keep media blocks for all dialects.
  _ = dialect
}

// MARK: - Request-Level Transform

/// Transform a full Context for cross-provider replay.
/// Returns a new Context with normalized messages ready for the target endpoint.
func transformedContext(
  _ context: Context,
  from sourceProviderID: String,
  to targetEndpoint: any ModelEndpoint,
) -> Context {
  var messages = context.messages
  transformMessages(&messages, from: sourceProviderID, to: targetEndpoint)
  return Context(
    systemPrompt: context.systemPrompt,
    messages: messages,
    tools: context.tools,
  )
}
