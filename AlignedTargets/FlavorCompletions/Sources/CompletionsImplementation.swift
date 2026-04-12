import AICore
import Dependencies
import Fetch
import Foundation
import HTTPTypes
import JSONUtilities

struct CompletionsRuntime {
  @Dependency(\.fetch) var fetch

  func infer(_ input: Input, target: ModelTarget) async throws -> Output {
    let stream = try await self.stream(input, target: target)
    return try await stream.result()
  }

  func stream(_ input: Input, target: ModelTarget) async throws -> AICore.OutputStream {
    try Completions.ensureFlavor(target.model)

    let request = try makeRequest(input: input, target: target)
    let state = StreamState()
    let eventStream = AsyncThrowingStream<OutputEvent, any Error> { continuation in
      state.continuation = continuation
    }

    let task = Task { () throws -> Output in
      do {
        let response = try await validatedResponse(for: request, using: self.fetch)
        let payload = try await parseJSONResponse(response)
        let output = try Completions.decode(payload, model: target.model)
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
    let url = target.model.endpoint.baseURL.appending(path: "chat").appending(path: "completions")
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
      body: try Completions.encode(input, model: target.model)
    )
  }
}

private final class StreamState: @unchecked Sendable {
  var continuation: AsyncThrowingStream<OutputEvent, any Error>.Continuation?
}

extension Completions {
  static func _encode(_ input: Input, model: Model) throws -> JSONValue {
    try ensureFlavor(model)

    var messages: [JSONValue] = []
    if let instructions = input.instructions, !instructions.isEmpty {
      messages.append(.object([
        "role": .string("system"),
        "content": .string(instructions),
      ]))
    }
    messages.append(contentsOf: encodeMessages(input.messages))

    var body: [String: JSONValue] = [
      "model": .string(model.id),
      "stream": .bool(false),
      "messages": .array(messages),
    ]

    let scope = input.options.completions
    if let store = scope.store {
      body["store"] = .bool(store)
    }
    if let toolChoice = scope.toolChoice, !input.tools.isEmpty {
      body["tool_choice"] = encodeToolChoice(toolChoice)
    }
    if let maxOutputTokens = input.options.maxOutputTokens {
      body["max_completion_tokens"] = .number(Double(maxOutputTokens))
    }
    if let temperature = input.options.temperature {
      body["temperature"] = .number(temperature)
    }

    if !input.tools.isEmpty {
      body["tools"] = .array(input.tools.map { tool in
        .object([
          "type": .string("function"),
          "function": .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": tool.inputSchema,
            "strict": .bool(false),
          ]),
        ])
      })
    }

    return .object(body)
  }

  static func _decode(_ response: JSONValue, model: Model) throws -> Output {
    try ensureFlavor(model)

    guard let object = response.object else {
      throw AIError.invalidResponse("Completions.decode expected object")
    }
    guard let choice = object["choices"]?.array?.first?.object else {
      throw AIError.invalidResponse("Completions.decode missing first choice")
    }
    guard let message = choice["message"]?.object else {
      throw AIError.invalidResponse("Completions.decode missing choice.message")
    }

    var items: [OutputItem] = []

    if let content = message["content"]?.stringValue,
       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      items.append(.text(.init(text: content)))
    } else if let contentParts = message["content"]?.array {
      let text = contentParts.compactMap { part -> String? in
        guard let object = part.object else { return nil }
        if object["type"]?.stringValue == "text" {
          return object["text"]?.stringValue
        }
        return nil
      }
      .joined(separator: "\n")
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        items.append(.text(.init(text: text)))
      }
    }

    for toolCallValue in message["tool_calls"]?.array ?? [] {
      guard let toolCall = toolCallValue.object,
            let function = toolCall["function"]?.object
      else { continue }

      let argumentsText = function["arguments"]?.stringValue ?? "{}"
      items.append(.toolCall(.init(
        id: toolCall["id"]?.stringValue ?? UUID().uuidString,
        name: function["name"]?.stringValue ?? "tool",
        arguments: parseJSONValueLenient(argumentsText) ?? .object([:])
      )))
    }

    let finishReason = choice["finish_reason"]?.stringValue
    let stopReason: StopReason = if items.contains(where: { if case .toolCall = $0 { return true } else { return false } }) {
      .toolUse
    } else {
      completionsStopReason(from: finishReason)
    }

    return Output(
      model: model,
      message: AssistantMessage(
        items: items,
        responseID: object["id"]?.stringValue,
        stopReason: stopReason
      ),
      usage: completionsUsage(from: object["usage"]?.object)
    )
  }
}

private func encodeMessages(_ messages: [Message]) -> [JSONValue] {
  messages.compactMap { message in
    switch message {
    case let .user(user):
      let text = user.content.compactMap { part -> String? in
        guard case let .text(text) = part else { return nil }
        return text.text
      }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)

      guard !text.isEmpty else { return nil }
      return .object([
        "role": .string("user"),
        "content": .string(text),
      ])

    case let .assistant(assistant):
      let text = assistant.items.compactMap { item -> String? in
        guard case let .text(text) = item else { return nil }
        let trimmed = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
      }
      .joined(separator: "\n")

      let toolCalls = assistant.items.compactMap { item -> JSONValue? in
        guard case let .toolCall(toolCall) = item else { return nil }
        return .object([
          "id": .string(toolCall.id),
          "type": .string("function"),
          "function": .object([
            "name": .string(toolCall.name),
            "arguments": .string(jsonString(toolCall.arguments)),
          ]),
        ])
      }

      guard !text.isEmpty || !toolCalls.isEmpty else { return nil }
      var object: [String: JSONValue] = [
        "role": .string("assistant"),
        "content": text.isEmpty ? .null : .string(text),
      ]
      if !toolCalls.isEmpty {
        object["tool_calls"] = .array(toolCalls)
      }
      return .object(object)

    case let .toolResult(toolResult):
      let text = toolResult.content.compactMap { part -> String? in
        guard case let .text(text) = part else { return nil }
        return text.text
      }
      .joined(separator: "\n")

      return .object([
        "role": .string("tool"),
        "tool_call_id": .string(toolResult.toolCallID),
        "content": .string(text.isEmpty ? "(no output)" : text),
      ])
    }
  }
}

private func encodeToolChoice(_ toolChoice: Completions.ToolChoice) -> JSONValue {
  switch toolChoice {
  case .automatic:
    return .string("auto")
  case .none:
    return .string("none")
  case .required:
    return .string("required")
  case let .tool(name):
    return .object([
      "type": .string("function"),
      "function": .object([
        "name": .string(name),
      ]),
    ])
  }
}

private func completionsStopReason(from value: String?) -> StopReason {
  switch value {
  case "tool_calls":
    return .toolUse
  case "length":
    return .length
  case "stop", "function_call":
    return .stop
  default:
    return .stop
  }
}

private func completionsUsage(from object: [String: JSONValue]?) -> Usage? {
  guard let object else { return nil }
  let inputTokens = Int(object["prompt_tokens"]?.doubleValue ?? 0)
  let outputTokens = Int(object["completion_tokens"]?.doubleValue ?? 0)
  let totalTokens = Int(object["total_tokens"]?.doubleValue ?? Double(inputTokens + outputTokens))
  return Usage(
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    totalTokens: totalTokens
  )
}

private func parseJSONValueLenient(_ text: String) -> JSONValue? {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
  do {
    return try JSONValue.fromAny(JSONSerialization.jsonObject(with: data))
  } catch {
    return nil
  }
}

private func jsonString(_ value: JSONValue) -> String {
  guard let data = try? JSONSerialization.data(withJSONObject: value.toAny(), options: [.sortedKeys]),
        let string = String(data: data, encoding: .utf8)
  else {
    return "{}"
  }
  return string
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
