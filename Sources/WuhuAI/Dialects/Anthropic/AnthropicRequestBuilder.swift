import Foundation
import JSONValue

// MARK: - Anthropic Request Builder

/// Build an Anthropic Messages API request body from domain types.
///
/// Wire format: Anthropic Messages API, SSE content-block streaming.
func buildAnthropicRequest(
  model: String,
  baseURL: URL,
  context: Context,
  options: RequestOptions,
) -> (url: URL, headers: [String: String], body: [String: JSONValue]) {
  let url = baseURL.appendingPathComponent("messages")

  let headers: [String: String] = [
    "content-type": "application/json",
    "accept": "text/event-stream",
    "anthropic-version": "2023-06-01",
  ]

  var body: [String: JSONValue] = [
    "model": .string(model),
    "messages": .array(buildMessages(context: context)),
    "stream": .bool(true),
    "max_tokens": .number(Double(options.maxTokens ?? 16384)),
  ]

  if let temperature = options.temperature {
    body["temperature"] = .number(temperature)
  }

  // System prompt
  if let system = context.systemPrompt, !system.isEmpty {
    body["system"] = .string(system)
  }

  // Tools
  if let tools = context.tools, !tools.isEmpty {
    body["tools"] = .array(tools.map(buildTool))
  }

  return (url, headers, body)
}

// MARK: - Messages

private func buildMessages(context: Context) -> [JSONValue] {
  var messages: [JSONValue] = []
  var i = 0

  while i < context.messages.count {
    let message = context.messages[i]

    switch message {
    case let .user(m):
      let blocks = buildUserContentBlocks(m.content)
      if !blocks.isEmpty {
        messages.append(.object([
          "role": .string("user"),
          "content": .array(blocks),
        ]))
      }
      i += 1

    case let .assistant(m):
      let blocks = buildAssistantContentBlocks(m.content)
      if !blocks.isEmpty {
        messages.append(.object([
          "role": .string("assistant"),
          "content": .array(blocks),
        ]))
      }
      i += 1

    case .toolResult:
      // Group consecutive tool results into one user message
      var toolResults: [JSONValue] = []
      while i < context.messages.count {
        guard case let .toolResult(m) = context.messages[i] else { break }

        let text = m.content.compactMap { block -> String? in
          if case let .text(t) = block { return t.text }
          return nil
        }.joined(separator: "\n")

        toolResults.append(.object([
          "type": .string("tool_result"),
          "tool_use_id": .string(m.toolCallId),
          "content": .string(text.isEmpty ? "(no output)" : text),
          "is_error": .bool(m.isError),
        ]))
        i += 1
      }

      if !toolResults.isEmpty {
        messages.append(.object([
          "role": .string("user"),
          "content": .array(toolResults),
        ]))
      }
    }
  }

  return messages
}

// MARK: - Content Blocks

private func buildUserContentBlocks(_ blocks: [ContentBlock]) -> [JSONValue] {
  var parts: [JSONValue] = []

  for block in blocks {
    switch block {
    case let .text(text):
      if !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        parts.append(.object([
          "type": .string("text"),
          "text": .string(text.text),
        ]))
      }

    case let .media(media):
      let urlString = media.url.absoluteString
      if urlString.hasPrefix("data:") {
        // data:image/png;base64,XXXX
        let base64 = extractBase64(from: urlString)
        if let b64 = base64 {
          parts.append(.object([
            "type": .string("image"),
            "source": .object([
              "type": .string("base64"),
              "media_type": .string(media.mimeType),
              "data": .string(b64),
            ]),
          ]))
        }
      }

    case .reasoning, .toolCall:
      break
    }
  }

  return parts
}

private func buildAssistantContentBlocks(_ blocks: [ContentBlock]) -> [JSONValue] {
  var parts: [JSONValue] = []

  for block in blocks {
    switch block {
    case let .text(text):
      if !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        parts.append(.object([
          "type": .string("text"),
          "text": .string(text.text),
        ]))
      }

    case let .reasoning(reasoning):
      if let block = buildAnthropicReasoningBlock(reasoning) {
        parts.append(block)
      }

    case let .toolCall(call):
      parts.append(.object([
        "type": .string("tool_use"),
        "id": .string(call.id),
        "name": .string(call.name),
        "input": call.arguments,
      ]))

    case .media:
      break
    }
  }

  return parts
}

// MARK: - Reasoning

private func buildAnthropicReasoningBlock(_ reasoning: ReasoningContent) -> JSONValue? {
  switch reasoning {
  case let .unencrypted(text):
    // Unencrypted reasoning → regular thinking
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return .object([
      "type": .string("thinking"),
      "thinking": .string(text),
    ])

  case let .encrypted(enc):
    // Redacted thinking (no summary, opaque only)
    if enc.redacted {
      return .object([
        "type": .string("redacted_thinking"),
        "data": .string(enc.opaque),
      ])
    }

    // Regular thinking with signature
    let text = enc.summary ?? ""
    let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasSignature = !enc.opaque.isEmpty
    guard hasText || hasSignature else { return nil }

    var block: [String: JSONValue] = [
      "type": .string("thinking"),
      "thinking": .string(text),
    ]
    if hasSignature {
      block["signature"] = .string(enc.opaque)
    }
    return .object(block)
  }
}

// MARK: - Tools

private func buildTool(_ tool: Tool) -> JSONValue {
  .object([
    "name": .string(tool.name),
    "description": .string(tool.description),
    "input_schema": tool.parameters,
  ])
}

// MARK: - Helpers

private func extractBase64(from dataURI: String) -> String? {
  // data:image/png;base64,XXXX
  guard let commaIndex = dataURI.firstIndex(of: ",") else { return nil }
  let index = dataURI.index(after: commaIndex)
  return String(dataURI[index...])
}
