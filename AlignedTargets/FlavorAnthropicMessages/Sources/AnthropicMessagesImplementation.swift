import AICore
import Dependencies
import Fetch
import Foundation
import HTTPTypes
import JSONUtilities

struct AnthropicMessagesRuntime {
  @Dependency(\.fetch) var fetch

  func infer(_ input: Input, target: ModelTarget) async throws -> Output {
    let stream = try await self.stream(input, target: target)
    return try await stream.result()
  }

  func stream(_ input: Input, target: ModelTarget) async throws -> AICore.OutputStream {
    try AnthropicMessages.ensureFlavor(target.model)

    let request = try makeRequest(input: input, target: target)
    let state = StreamState()
    let eventStream = AsyncThrowingStream<OutputEvent, any Error> { continuation in
      state.continuation = continuation
    }

    let task = Task { () throws -> Output in
      do {
        let response = try await validatedResponse(for: request, using: self.fetch)
        let payload = try await parseJSONResponse(response)
        let output = try AnthropicMessages.decode(payload, model: target.model)
        state.continuation?.yield(.complete(output))
        state.continuation?.finish()
        return output
      } catch {
        state.continuation?.finish(throwing: error)
        throw error
      }
    }

    state.continuation?.onTermination = { _ in
      task.cancel()
    }

    return OutputStream(
      stream: eventStream,
      resultOperation: {
        try await task.value
      }
    )
  }

  private func makeRequest(input: Input, target: ModelTarget) throws -> Request {
    let url = target.model.endpoint.baseURL.appending(path: "messages")
    var headers = Headers()

    for (name, value) in target.model.defaultHeaders {
      setHeader(value, for: name, in: &headers)
    }
    for (name, value) in target.headers {
      setHeader(value, for: name, in: &headers)
    }
    for (name, value) in target.sensitiveHeaders {
      setHeader(value, for: name, in: &headers)
    }
    for (name, value) in input.options.additionalHeaders {
      setHeader(value, for: name, in: &headers)
    }

    headers[.contentType] = "application/json"
    headers[.accept] = "application/json"

    return try makeJSONRequest(
      url: url,
      headers: headers,
      body: try AnthropicMessages.encode(input, model: target.model)
    )
  }
}

private final class StreamState: @unchecked Sendable {
  var continuation: AsyncThrowingStream<OutputEvent, any Error>.Continuation?
}

extension AnthropicMessages {
  static func _encode(_ input: Input, model: Model) throws -> JSONValue {
    try ensureFlavor(model)

    var body: [String: JSONValue] = [
      "model": .string(model.id),
      "stream": .bool(false),
      "messages": .array(try encodeMessages(input.messages)),
      "max_tokens": .number(Double(input.options.maxOutputTokens ?? 1024)),
    ]

    if let instructions = input.instructions, !instructions.isEmpty {
      body["system"] = .string(instructions)
    }

    if !input.tools.isEmpty {
      body["tools"] = .array(input.tools.map { tool in
        .object([
          "name": .string(tool.name),
          "description": .string(tool.description),
          "input_schema": tool.inputSchema,
        ])
      })
    }

    return .object(body)
  }

  static func _decode(_ response: JSONValue, model: Model) throws -> Output {
    try ensureFlavor(model)

    guard let object = response.object else {
      throw AIError.invalidResponse("AnthropicMessages.decode expected object")
    }

    let items: [OutputItem] = (object["content"]?.array ?? []).compactMap { block in
      guard let object = block.object, let type = object["type"]?.stringValue else { return nil }

      switch type {
      case "text":
        return .text(.init(text: object["text"]?.stringValue ?? ""))

      case "tool_use":
        return .toolCall(
          .init(
            id: object["id"]?.stringValue ?? UUID().uuidString,
            name: object["name"]?.stringValue ?? "tool",
            arguments: object["input"] ?? .object([:])
          )
        )

      default:
        return nil
      }
    }

    return Output(
      model: model,
      message: AssistantMessage(
        items: items,
        responseID: object["id"]?.stringValue,
        stopReason: anthropicStopReason(from: object["stop_reason"]?.stringValue)
      ),
      usage: anthropicUsage(from: object["usage"]?.object)
    )
  }
}

private func encodeMessages(_ messages: [Message]) throws -> [JSONValue] {
  var encoded: [JSONValue] = []
  var index = 0

  while index < messages.count {
    switch messages[index] {
    case let .user(user):
      let text = user.content.compactMap { part -> String? in
        guard case let .text(text) = part else { return nil }
        return text.text
      }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)

      let imageBlocks = try user.content.compactMap { part -> JSONValue? in
        guard case let .media(media) = part, media.kind == .image else { return nil }
        return try encodeAnthropicImageBlock(media)
      }

      if imageBlocks.isEmpty {
        if !text.isEmpty {
          encoded.append(.object([
            "role": .string("user"),
            "content": .array([
              .object([
                "type": .string("text"),
                "text": .string(text),
              ])
            ]),
          ]))
        }
      } else {
        var contentBlocks: [JSONValue] = [
          .object([
            "type": .string("text"),
            "text": .string(text.isEmpty ? "(see attached image)" : text),
          ])
        ]
        contentBlocks.append(contentsOf: imageBlocks)
        encoded.append(.object([
          "role": .string("user"),
          "content": .array(contentBlocks),
        ]))
      }
      index += 1

    case let .assistant(assistant):
      let blocks = assistant.items.compactMap { item -> JSONValue? in
        switch item {
        case let .text(text):
          let trimmed = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { return nil }
          return .object([
            "type": .string("text"),
            "text": .string(trimmed),
          ])

        case let .toolCall(toolCall):
          return .object([
            "type": .string("tool_use"),
            "id": .string(toolCall.id),
            "name": .string(toolCall.name),
            "input": toolCall.arguments,
          ])

        case .reasoning:
          return nil
        }
      }

      if !blocks.isEmpty {
        encoded.append(.object([
          "role": .string("assistant"),
          "content": .array(blocks),
        ]))
      }
      index += 1

    case .toolResult:
      var results: [JSONValue] = []
      while index < messages.count {
        guard case let .toolResult(toolResult) = messages[index] else { break }

        let text = toolResult.content.compactMap { part -> String? in
          guard case let .text(text) = part else { return nil }
          return text.text
        }
        .joined(separator: "\n")

        let imageBlocks = try toolResult.content.compactMap { part -> JSONValue? in
          guard case let .media(media) = part, media.kind == .image else { return nil }
          return try encodeAnthropicImageBlock(media)
        }

        if imageBlocks.isEmpty {
          results.append(.object([
            "type": .string("tool_result"),
            "tool_use_id": .string(toolResult.toolCallID),
            "content": .string(text.isEmpty ? "(no output)" : text),
            "is_error": .bool(toolResult.isError),
          ]))
        } else {
          var contentBlocks: [JSONValue] = []
          if !text.isEmpty {
            contentBlocks.append(.object([
              "type": .string("text"),
              "text": .string(text),
            ]))
          }
          contentBlocks.append(contentsOf: imageBlocks)
          results.append(.object([
            "type": .string("tool_result"),
            "tool_use_id": .string(toolResult.toolCallID),
            "content": .array(contentBlocks),
            "is_error": .bool(toolResult.isError),
          ]))
        }

        index += 1
      }

      if !results.isEmpty {
        encoded.append(.object([
          "role": .string("user"),
          "content": .array(results),
        ]))
      }
    }
  }

  return encoded
}

private func encodeAnthropicImageBlock(_ media: MediaPart) throws -> JSONValue {
  let base64Data: String = switch media.source {
  case let .data(data):
    data.base64EncodedString()
  case .remoteURL:
    throw AIError.unimplemented("AnthropicMessages image remoteURL is not supported")
  case .fileReference:
    throw AIError.unimplemented("AnthropicMessages image fileReference is not supported")
  }

  return .object([
    "type": .string("image"),
    "source": .object([
      "type": .string("base64"),
      "media_type": .string(media.mimeType),
      "data": .string(base64Data),
    ]),
  ])
}

private func anthropicStopReason(from value: String?) -> StopReason {
  switch value {
  case "tool_use":
    return .toolUse
  case "max_tokens":
    return .length
  case "end_turn", "stop_sequence":
    return .stop
  case "pause_turn":
    return .stop
  default:
    return .stop
  }
}

private func anthropicUsage(from object: [String: JSONValue]?) -> Usage? {
  guard let object else { return nil }
  let inputTokens = Int(object["input_tokens"]?.doubleValue ?? 0)
  let outputTokens = Int(object["output_tokens"]?.doubleValue ?? 0)
  let cacheCreation = Int(object["cache_creation_input_tokens"]?.doubleValue ?? 0)
  let cacheRead = Int(object["cache_read_input_tokens"]?.doubleValue ?? 0)
  let total = inputTokens + outputTokens + cacheCreation + cacheRead
  return Usage(
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cacheReadTokens: cacheRead,
    cacheWriteTokens: cacheCreation,
    totalTokens: total
  )
}

private func parseJSONResponse(_ response: Response) async throws -> JSONValue {
  let text = try await response.text(upTo: 256 * 1024)
  let data = Data(text.utf8)
  return try JSONValue.fromAny(JSONSerialization.jsonObject(with: data))
}

private func makeJSONRequest(url: URL, headers: Headers, body: JSONValue) throws -> Request {
  let data = try JSONSerialization.data(withJSONObject: body.toAny(), options: [.sortedKeys])
  return Request(
    url: url,
    method: .post,
    headers: headers,
    body: .bytes(Array(data), contentType: "application/json")
  )
}

private func setHeader(_ value: String, for name: String, in headers: inout Headers) {
  guard let fieldName = HTTPField.Name(name) else { return }
  headers[fieldName] = value
}

private func validatedResponse(for request: Request, using fetch: FetchClient) async throws -> Response {
  let response = try await fetch(request)
  guard (200..<300).contains(response.status.code) else {
    let body = try? await response.text(upTo: 64 * 1024)
    throw AIError.upstream(statusCode: response.status.code, message: body ?? "HTTP \(response.status.code)")
  }
  return response
}
