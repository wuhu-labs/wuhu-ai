import Foundation
import JSONValue

// MARK: - Responses Request Builder

/// Build an OpenAI Responses API request body from domain types.
///
/// Wire format: OpenAI `/v1/responses`, SSE streaming.
func buildResponsesRequest(
  model: String,
  baseURL: URL,
  context: Context,
  options: RequestOptions,
  isCodex: Bool,
) -> (url: URL, headers: [String: String], body: [String: JSONValue]) {
  let url = baseURL.appendingPathComponent("responses")

  let headers: [String: String] = [
    "content-type": "application/json",
    "accept": "text/event-stream",
  ]

  var body: [String: JSONValue] = [
    "model": .string(model),
    "input": .array(buildInput(context: context, isCodex: isCodex)),
    "stream": .bool(true),
    "store": .bool(false),
  ]

  if !isCodex {
    // Standard OpenAI: reasoning config
    switch options.reasoning {
    case .none:
      break
    case .automatic:
      body["reasoning"] = .object(["effort": .string("medium")])
      body["include"] = .array([.string("reasoning.encrypted_content")])
    case .effort(let effort):
      body["reasoning"] = .object(["effort": .string(effort)])
      body["include"] = .array([.string("reasoning.encrypted_content")])
    case .budget(let tokens):
      body["reasoning"] = .object([
        "effort": .string("medium"),
        "max_tokens": .number(Double(tokens)),
      ])
      body["include"] = .array([.string("reasoning.encrypted_content")])
    }
  }

  if let temperature = options.temperature {
    body["temperature"] = .number(temperature)
  }
  if let maxTokens = options.maxTokens {
    body["max_output_tokens"] = .number(Double(maxTokens))
  }

  if let tools = context.tools, !tools.isEmpty {
    body["tools"] = .array(tools.map(buildTool))
  }

  // Codex: instructions go into body (handled by endpoint's modifyBody)
  if isCodex, let systemPrompt = context.systemPrompt {
    body["instructions"] = .string(systemPrompt)
  }

  return (url, headers, body)
}

// MARK: - Input

private func buildInput(context: Context, isCodex: Bool) -> [JSONValue] {
  var input: [JSONValue] = []

  // System prompt
  if !isCodex, let system = context.systemPrompt, !system.isEmpty {
    input.append(.object([
      "role": .string("system"),
      "content": .string(system),
    ]))
  }

  var msgIndex = 0

  for message in context.messages {
    switch message {
    case let .user(m):
      let text = m.content.compactMap { block -> String? in
        if case let .text(t) = block { return t.text }
        return nil
      }.joined(separator: "\n")

      let imageBlocks: [JSONValue] = m.content.compactMap { block in
        guard case let .media(media) = block
        else { return nil }

        let urlString = media.url.absoluteString
        if urlString.hasPrefix("data:") || urlString.hasPrefix("https://") {
          return .object([
            "type": .string("input_image"),
            "detail": .string("auto"),
            "image_url": .string(urlString),
          ])
        }
        return nil
      }

      if imageBlocks.isEmpty {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        input.append(.object([
          "role": .string("user"),
          "content": .array([
            .object([
              "type": .string("input_text"),
              "text": .string(text),
            ]),
          ]),
        ]))
      } else {
        var contentBlocks: [JSONValue] = []
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          contentBlocks.append(.object([
            "type": .string("input_text"),
            "text": .string(text),
          ]))
        }
        contentBlocks.append(contentsOf: imageBlocks)
        input.append(.object([
          "role": .string("user"),
          "content": .array(contentBlocks),
        ]))
      }

    case let .assistant(m):
      for block in m.content {
        switch block {
        case let .text(part):
          let id = "msg_\(msgIndex)"
          input.append(.object([
            "type": .string("message"),
            "role": .string("assistant"),
            "content": .array([
              .object([
                "type": .string("output_text"),
                "text": .string(part.text),
                "annotations": .array([]),
              ]),
            ]),
            "status": .string("completed"),
            "id": .string(id),
          ]))
          msgIndex += 1

          if let phase = m.phase {
            if case var .object(lastObj) = input[input.count - 1] {
              lastObj["phase"] = .string(phase.rawValue)
              input[input.count - 1] = .object(lastObj)
            }
          }

        case let .toolCall(call):
          let (callID, itemID) = splitToolCallID(call.id)
          var obj: [String: JSONValue] = [
            "type": .string("function_call"),
            "call_id": .string(callID),
            "name": .string(call.name),
            "arguments": .string(call.arguments.jsonString()),
          ]
          if let itemID {
            obj["id"] = .string(itemID)
          }
          input.append(.object(obj))

        case let .reasoning(reasoning):
          switch reasoning {
          case let .unencrypted(text):
            input.append(.object([
              "type": .string("reasoning"),
              "id": .string(UUID().uuidString),
              "summary": .array([
                .object([
                  "type": .string("summary_text"),
                  "text": .string(text),
                ]),
              ]),
            ]))

          case let .encrypted(enc):
            var obj: [String: JSONValue] = [
              "type": .string("reasoning"),
              "id": .string(enc.id ?? UUID().uuidString),
              "summary": .array([]),
            ]
            if !enc.opaque.isEmpty {
              obj["encrypted_content"] = .string(enc.opaque)
            }
            if let summary = enc.summary {
              obj["summary"] = .array([
                .object([
                  "type": .string("summary_text"),
                  "text": .string(summary),
                ]),
              ])
            }
            input.append(.object(obj))
          }

        case .media:
          // Media in assistant messages not supported in Responses.
          break
        }
      }

    case let .toolResult(m):
      let outputText = m.content.compactMap { block -> String? in
        if case let .text(t) = block { return t.text }
        return nil
      }.joined(separator: "\n")

      let (callID, _) = splitToolCallID(m.toolCallId)

      input.append(.object([
        "type": .string("function_call_output"),
        "call_id": .string(callID),
        "output": .string(outputText.isEmpty ? "(no output)" : outputText),
      ]))
    }
  }

  return input
}

// MARK: - Tools

private func buildTool(_ tool: Tool) -> JSONValue {
  .object([
    "type": .string("function"),
    "name": .string(tool.name),
    "description": .string(tool.description),
    "parameters": tool.parameters,
    "strict": .bool(false),
  ])
}

// MARK: - Helpers

func splitToolCallID(_ id: String) -> (callID: String, itemID: String?) {
  let parts = id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
  if parts.count == 2 {
    return (String(parts[0]), String(parts[1]))
  }
  return (id, nil)
}
