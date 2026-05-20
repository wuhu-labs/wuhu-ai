import Foundation
import JSONValue

// MARK: - Gemini Request Builder

/// Build a Google Gemini API request body from domain types.
///
/// Wire format: Google Gemini API (`@google/genai` protocol).
func buildGeminiRequest(
  model: String,
  baseURL: URL,
  context: Context,
  options: RequestOptions,
) -> (url: URL, headers: [String: String], body: [String: JSONValue]) {
  let url = baseURL
    .appendingPathComponent("models")
    .appendingPathComponent("\(model):streamGenerateContent")
    .appending(queryItems: [URLQueryItem(name: "alt", value: "sse")])

  let headers: [String: String] = [
    "content-type": "application/json",
  ]

  var body: [String: JSONValue] = [:]

  // System instruction
  if let system = context.systemPrompt, !system.isEmpty {
    body["systemInstruction"] = .object([
      "parts": .array([
        .object(["text": .string(system)]),
      ]),
    ])
  }

  // Contents
  body["contents"] = .array(buildContents(context: context))

  // Generation config
  var generationConfig: [String: JSONValue] = [:]
  if let temperature = options.temperature {
    generationConfig["temperature"] = .number(temperature)
  }
  if let maxTokens = options.maxTokens {
    generationConfig["maxOutputTokens"] = .number(Double(maxTokens))
  }
  if !generationConfig.isEmpty {
    body["generationConfig"] = .object(generationConfig)
  }

  // Tools
  if let tools = context.tools, !tools.isEmpty {
    body["tools"] = .array([
      .object([
        "functionDeclarations": .array(tools.map(buildTool)),
      ]),
    ])
  }

  return (url, headers, body)
}

// MARK: - Contents

private func buildContents(context: Context) -> [JSONValue] {
  var contents: [JSONValue] = []
  var i = 0

  while i < context.messages.count {
    let message = context.messages[i]

    switch message {
    case let .user(m):
      var parts: [JSONValue] = []

      for block in m.content {
        switch block {
        case let .text(text):
          if !text.text.isEmpty {
            parts.append(.object(["text": .string(text.text)]))
          }

        case let .media(media):
          let urlString = media.url.absoluteString
          if urlString.hasPrefix("data:") {
            let base64 = extractBase64(from: urlString)
            if let b64 = base64 {
              parts.append(.object([
                "inlineData": .object([
                  "mimeType": .string(media.mimeType),
                  "data": .string(b64),
                ]),
              ]))
            }
          } else if urlString.hasPrefix("https://") || urlString.hasPrefix("gs://") {
            parts.append(.object([
              "fileData": .object([
                "mimeType": .string(media.mimeType),
                "fileUri": .string(urlString),
              ]),
            ]))
          }

        case .reasoning, .toolCall:
          break
        }
      }

      if !parts.isEmpty {
        contents.append(.object([
          "role": .string("user"),
          "parts": .array(parts),
        ]))
      }
      i += 1

    case let .assistant(m):
      var parts: [JSONValue] = []

      for (j, block) in m.content.enumerated() {
        // Gemini thoughtSignature fusion: if an encrypted reasoning block
        // sits immediately before a text/toolCall block,
        // attach thoughtSignature to that part.
        let nextBlock = j + 1 < m.content.count ? m.content[j + 1] : nil

        switch block {
        case let .text(text):
          var part: [String: JSONValue] = ["text": .string(text.text)]

          // Check if previous block was encrypted reasoning for fusion
          if j > 0, case let .reasoning(reasoning) = m.content[j - 1],
             case let .encrypted(enc) = reasoning,
             !enc.opaque.isEmpty
          {
            // Attach thoughtSignature
            part["thoughtSignature"] = .string(enc.opaque)
          }

          parts.append(.object(part))

        case let .reasoning(reasoning):
          switch reasoning {
          case .unencrypted:
            // Unencrypted reasoning → standalone thought part
            var thoughtPart: [String: JSONValue] = ["thought": .bool(true)]
            if case let .unencrypted(text) = reasoning {
              thoughtPart["text"] = .string(text)
            }
            parts.append(.object(thoughtPart))

          case let .encrypted(enc):
            // Check if this should be fused (followed by text/toolCall)
            if let next = nextBlock,
               case .text = next
            {
              continue
            }
            if let next = nextBlock,
               case .toolCall = next
            {
              continue
            }

            // Standalone thought part
            var thoughtPart: [String: JSONValue] = [
              "thought": .bool(true),
            ]
            if let text = enc.summary {
              thoughtPart["text"] = .string(text)
            }
            if !enc.opaque.isEmpty {
              thoughtPart["thoughtSignature"] = .string(enc.opaque)
            }
            parts.append(.object(thoughtPart))
          }

        case let .toolCall(call):
          var funcPart: [String: JSONValue] = [
            "functionCall": .object([
              "name": .string(call.name),
              "args": call.arguments,
            ]),
          ]

          // Check if previous block was encrypted reasoning for fusion
          if j > 0, case let .reasoning(reasoning) = m.content[j - 1],
             case let .encrypted(enc) = reasoning,
             !enc.opaque.isEmpty
          {
            funcPart["thoughtSignature"] = .string(enc.opaque)
          }

          parts.append(.object(funcPart))

        case .media:
          break
        }
      }

      if !parts.isEmpty {
        contents.append(.object([
          "role": .string("model"),
          "parts": .array(parts),
        ]))
      }
      i += 1

    case .toolResult:
      // Group consecutive tool results
      var toolResultParts: [JSONValue] = []
      while i < context.messages.count {
        guard case let .toolResult(m) = context.messages[i] else { break }

        // Derive tool name from the matching ToolCall in preceding messages.
        let toolName = deriveToolName(for: m.toolCallId, from: context.messages, before: i)

        var response: [String: JSONValue] = [
          "name": .string(toolName),
        ]

        let text = m.content.compactMap { block -> String? in
          if case let .text(t) = block { return t.text }
          return nil
        }.joined(separator: "\n")

        // Try to parse JSON, fallback to string.
        // Gemini requires response to be an object (Struct), so wrap
        // bare primitives (numbers, strings, etc.) in {"result": ...}.
        if let parsed = JSONValue.parse(text) {
          if case .object = parsed {
            response["response"] = parsed
          } else {
            response["response"] = .object(["result": parsed])
          }
        } else {
          response["response"] = .object(["result": .string(text)])
        }

        toolResultParts.append(.object([
          "functionResponse": .object(response),
        ]))
        i += 1
      }

      if !toolResultParts.isEmpty {
        contents.append(.object([
          "role": .string("user"),
          "parts": .array(toolResultParts),
        ]))
      }
    }
  }

  return contents
}

// MARK: - Tools

private func buildTool(_ tool: Tool) -> JSONValue {
  .object([
    "name": .string(tool.name),
    "description": .string(tool.description),
    "parameters": tool.parameters,
  ])
}

// MARK: - Helpers

/// Derive a tool name by scanning preceding messages for the matching ToolCall.
private func deriveToolName(for toolCallId: String, from messages: [Message], before index: Int) -> String {
  // Scan backward through messages to find the matching ToolCall.
  for msg in messages[..<index].reversed() {
    guard case let .assistant(m) = msg else { continue }
    for block in m.content {
      guard case let .toolCall(tc) = block else { continue }
      if tc.id == toolCallId {
        return tc.name
      }
      // Also try matching the compound ID (Responses format: "call_id|item_id")
      if let pipeIndex = toolCallId.firstIndex(of: "|"),
         tc.id == String(toolCallId[..<pipeIndex])
      {
        return tc.name
      }
    }
  }
  return "tool"
}

private func extractBase64(from dataURI: String) -> String? {
  guard let commaIndex = dataURI.firstIndex(of: ",") else { return nil }
  let index = dataURI.index(after: commaIndex)
  return String(dataURI[index...])
}
