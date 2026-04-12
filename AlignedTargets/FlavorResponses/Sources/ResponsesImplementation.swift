import AICore
import Dependencies
import Fetch
import FetchSSE
import Foundation
import HTTPTypes
import JSONUtilities

struct ResponsesRuntime {
  @Dependency(\.fetch) var fetch

  func infer(_ input: Input, target: ModelTarget) async throws -> Output {
    let stream = try await self.stream(input, target: target)
    return try await stream.result()
  }

  func stream(_ input: Input, target: ModelTarget) async throws -> AICore.OutputStream {
    try Responses.ensureFlavor(target)

    let request = try makeRequest(input: input, target: target)

    let state = StreamState()
    let eventStream = AsyncThrowingStream<OutputEvent, any Error> { continuation in
      state.continuation = continuation
    }

    let task = Task { () throws -> Output in
      do {
        let response = try await validatedResponse(for: request, using: self.fetch)
        var parser = Responses.makeStreamingParser(model: target.model)

        for try await message in response.sse() {
          if let payload = try parseEventJSON(message.data) {
            for event in try parser.consume(payload) {
              state.continuation?.yield(event)
            }
          }
        }

        let output = try parser.finish()
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
    let url = target.model.endpoint.baseURL.appending(path: "responses")
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
    headers[.accept] = "text/event-stream"

    return try makeJSONRequest(
      url: url,
      headers: headers,
      body: try Responses.encode(input, model: target.model)
    )
  }
}

private final class StreamState: @unchecked Sendable {
  var continuation: AsyncThrowingStream<OutputEvent, any Error>.Continuation?
}

extension Responses {
  static func _encode(_ input: Input, model: Model) throws -> JSONValue {
    try ensureFlavor(model)

    let scope = input.options.responses
    var body: [String: JSONValue] = [
      "model": .string(model.id),
      "stream": .bool(true),
      "input": .array(try encodeMessages(input.messages)),
    ]

    if let instructions = input.instructions, !instructions.isEmpty {
      body["instructions"] = .string(instructions)
    }
    if let promptCacheKey = scope.promptCacheKey {
      body["prompt_cache_key"] = .string(promptCacheKey)
    }
    if let previousResponseID = scope.previousResponseID {
      body["previous_response_id"] = .string(previousResponseID)
    }
    if let store = scope.store {
      body["store"] = .bool(store)
    }
    if let serviceTier = scope.serviceTier {
      let rawValue = serviceTier == .defaultTier ? "default" : serviceTier.rawValue
      body["service_tier"] = .string(rawValue)
    }
    if let maxOutputTokens = input.options.maxOutputTokens {
      body["max_output_tokens"] = .number(Double(maxOutputTokens))
    }
    if let temperature = input.options.temperature {
      body["temperature"] = .number(temperature)
    }

    switch scope.reasoning {
    case .disabled:
      break
    case let .effort(effort, summary):
      body["reasoning"] = .object([
        "effort": .string(encodedReasoningEffort(modelID: model.id, effort: effort)),
        "summary": .string(encodedReasoningSummary(summary)),
      ])
      body["include"] = .array([
        .string("reasoning.encrypted_content")
      ])
    }

    if !input.tools.isEmpty {
      body["tools"] = .array(input.tools.map(encodeTool))
    }

    return .object(body)
  }

  static func _decode(_ response: JSONValue, model: Model) throws -> Output {
    _ = response
    try ensureFlavor(model)
    throw AIError.unimplemented("Responses.decode")
  }
}

extension Responses.Parser {
  mutating func _consume(_ event: JSONValue) throws -> [OutputEvent] {
    guard let object = event.object, let type = object["type"]?.stringValue else {
      return []
    }

    var emitted: [OutputEvent] = []
    if !self.didStart {
      emitted.append(.start(partial: self.output))
      self.didStart = true
    }

    switch type {
    case "response.created":
      if let response = object["response"]?.object, let id = response["id"]?.stringValue {
        self.output.message.responseID = id
      }

    case "response.output_item.added":
      if let item = object["item"]?.object {
        emitted.append(contentsOf: self.handleOutputItemAdded(item))
      }

    case "response.output_text.delta":
      let delta = object["delta"]?.stringValue ?? ""
      if let index = self.currentTextIndex,
         case var .text(text) = self.output.message.items[index]
      {
        text.text += delta
        self.output.message.items[index] = .text(text)
        emitted.append(.textDelta(index: index, delta: delta, partial: self.output))
      }

    case "response.reasoning_summary_text.delta":
      let delta = object["delta"]?.stringValue ?? ""
      if let index = self.currentReasoningIndex,
         case var .reasoning(reasoning) = self.output.message.items[index]
      {
        reasoning.summary = (reasoning.summary ?? "") + delta
        self.output.message.items[index] = .reasoning(reasoning)
        emitted.append(.reasoningDelta(index: index, delta: delta, partial: self.output))
      }

    case "response.reasoning_summary_text.done":
      if let index = self.currentReasoningIndex,
         case let .reasoning(reasoning) = self.output.message.items[index]
      {
        emitted.append(.reasoningEnd(index: index, text: reasoning.summary ?? "", partial: self.output))
      }

    case "response.function_call_arguments.delta":
      let delta = object["delta"]?.stringValue ?? ""
      self.currentToolCallArgumentsBuffer += delta
      if let index = self.currentToolCallIndex,
         case var .toolCall(toolCall) = self.output.message.items[index]
      {
        if let arguments = parseJSONValueLenient(self.currentToolCallArgumentsBuffer) {
          toolCall.arguments = arguments
          self.output.message.items[index] = .toolCall(toolCall)
        }
        emitted.append(.toolCallDelta(index: index, delta: delta, partial: self.output))
      }

    case "response.output_item.done":
      if let item = object["item"]?.object {
        emitted.append(contentsOf: self.handleOutputItemDone(item))
      }

    case "response.completed":
      if let response = object["response"]?.object {
        self.output.message.responseID = response["id"]?.stringValue ?? self.output.message.responseID
        self.output.message.stopReason = completedStopReason(from: response)
        self.output.usage = parseUsage(from: response)
        if self.output.message.items.contains(where: { if case .toolCall = $0 { return true } else { return false } }) {
          self.output.message.stopReason = .toolUse
        }
      }

    case "error":
      throw AIError.invalidResponse(object["message"]?.stringValue ?? "OpenAI Responses stream error")

    default:
      break
    }

    return emitted
  }

  mutating func _finish() throws -> Output {
    if !self.didStart {
      throw AIError.invalidResponse("Responses parser finished before any events were consumed")
    }
    return self.output
  }

  private mutating func handleOutputItemAdded(_ item: [String: JSONValue]) -> [OutputEvent] {
    guard let itemType = item["type"]?.stringValue else { return [] }

    switch itemType {
    case "message":
      self.output.message.phase = item["phase"]?.stringValue ?? self.output.message.phase
      self.output.message.items.append(.text(.init(text: "", signature: item["id"]?.stringValue)))
      let index = self.output.message.items.endIndex - 1
      self.currentTextIndex = index
      self.currentReasoningIndex = nil
      self.currentToolCallIndex = nil
      self.currentToolCallArgumentsBuffer = ""
      return [.textStart(index: index, partial: self.output)]

    case "function_call":
      let callID = item["call_id"]?.stringValue ?? UUID().uuidString
      let itemID = item["id"]?.stringValue
      let fullID = itemID.map { "\(callID)|\($0)" } ?? callID
      self.output.message.items.append(.toolCall(.init(
        id: fullID,
        name: item["name"]?.stringValue ?? "tool",
        arguments: .object([:]),
        signature: nil
      )))
      let index = self.output.message.items.endIndex - 1
      self.currentToolCallIndex = index
      self.currentToolCallArgumentsBuffer = item["arguments"]?.stringValue ?? ""
      self.currentTextIndex = nil
      self.currentReasoningIndex = nil
      return [.toolCallStart(index: index, partial: self.output)]

    case "reasoning":
      self.output.message.items.append(.reasoning(.init(
        id: item["id"]?.stringValue,
        text: nil,
        summary: summaryText(from: item["summary"]),
        signature: item["encrypted_content"]?.stringValue,
        redacted: item["encrypted_content"] != nil
      )))
      let index = self.output.message.items.endIndex - 1
      self.currentReasoningIndex = index
      self.currentTextIndex = nil
      self.currentToolCallIndex = nil
      self.currentToolCallArgumentsBuffer = ""
      return [.reasoningStart(index: index, partial: self.output)]

    default:
      return []
    }
  }

  private mutating func handleOutputItemDone(_ item: [String: JSONValue]) -> [OutputEvent] {
    guard let itemType = item["type"]?.stringValue else { return [] }

    switch itemType {
    case "message":
      defer { self.currentTextIndex = nil }
      if let index = self.currentTextIndex,
         case let .text(text) = self.output.message.items[index]
      {
        self.output.message.phase = item["phase"]?.stringValue ?? self.output.message.phase
        return [.textEnd(index: index, text: text.text, partial: self.output)]
      }
      return []

    case "function_call":
      defer {
        self.currentToolCallIndex = nil
        self.currentToolCallArgumentsBuffer = ""
      }
      if let index = self.currentToolCallIndex,
         case var .toolCall(toolCall) = self.output.message.items[index]
      {
        let argumentsText = item["arguments"]?.stringValue ?? self.currentToolCallArgumentsBuffer
        if let arguments = parseJSONValueLenient(argumentsText) {
          toolCall.arguments = arguments
          self.output.message.items[index] = .toolCall(toolCall)
        }
        return [.toolCallEnd(index: index, toolCall: toolCall, partial: self.output)]
      }
      return []

    case "reasoning":
      defer { self.currentReasoningIndex = nil }
      if let index = self.currentReasoningIndex,
         case var .reasoning(reasoning) = self.output.message.items[index]
      {
        reasoning.signature = item["encrypted_content"]?.stringValue ?? reasoning.signature
        reasoning.summary = summaryText(from: item["summary"]) ?? reasoning.summary
        self.output.message.items[index] = .reasoning(reasoning)
        return [.reasoningEnd(index: index, text: reasoning.summary ?? "", partial: self.output)]
      }
      return []

    default:
      return []
    }
  }
}

private func encodedReasoningEffort(modelID: String, effort: Responses.Effort) -> String {
  let normalized = modelID.split(separator: "/").last.map(String.init) ?? modelID
  if normalized.hasPrefix("gpt-5.4"), effort == .minimal {
    return Responses.Effort.low.rawValue
  }
  return effort.rawValue
}

private func encodedReasoningSummary(_ summary: Responses.Summary) -> String {
  switch summary {
  case .automatic:
    return "auto"
  case let summary:
    return summary.rawValue
  }
}

private func parseUsage(from response: [String: JSONValue]) -> Usage? {
  guard let usage = response["usage"]?.object else { return nil }
  let inputTokens = Int((usage["input_tokens"]?.doubleValue) ?? 0)
  let outputTokens = Int((usage["output_tokens"]?.doubleValue) ?? 0)
  let totalTokens = Int((usage["total_tokens"]?.doubleValue) ?? Double(inputTokens + outputTokens))
  let cachedInput = Int((usage["input_tokens_details"]?.object?["cached_tokens"]?.doubleValue) ?? 0)
  return Usage(
    inputTokens: inputTokens - cachedInput,
    outputTokens: outputTokens,
    cacheReadTokens: cachedInput,
    cacheWriteTokens: 0,
    totalTokens: totalTokens
  )
}

private func completedStopReason(from response: [String: JSONValue]) -> StopReason {
  switch response["status"]?.stringValue {
  case "completed":
    return .stop
  case "incomplete":
    return .length
  case "failed", "cancelled":
    return .error
  default:
    return .stop
  }
}

private func encodeMessages(_ messages: [Message]) throws -> [JSONValue] {
  try messages.flatMap { message in
    switch message {
    case let .user(user):
      return [JSONValue.object([
        "role": .string("user"),
        "content": .array(try encodeUserContent(user.content)),
      ])]
    case let .assistant(assistant):
      return encodeAssistantMessage(assistant)
    case let .toolResult(toolResult):
      return try encodeToolResult(toolResult)
    }
  }
}

private func encodeUserContent(_ parts: [InputPart]) throws -> [JSONValue] {
  try parts.map { part in
    switch part {
    case let .text(text):
      return .object([
        "type": .string("input_text"),
        "text": .string(text.text),
      ])
    case let .media(media):
      return try encodeMediaPart(media)
    }
  }
}

private func encodeAssistantMessage(_ assistant: AssistantMessage) -> [JSONValue] {
  assistant.items.map { item in
    switch item {
    case let .text(text):
      var object: [String: JSONValue] = [
        "type": .string("message"),
        "role": .string("assistant"),
        "content": .array([
          .object([
            "type": .string("output_text"),
            "text": .string(text.text),
            "annotations": .array([]),
          ])
        ]),
        "status": .string("completed"),
      ]
      if let signature = text.signature {
        object["id"] = .string(signature)
      }
      if let phase = assistant.phase {
        object["phase"] = .string(phase)
      }
      return .object(object)

    case let .toolCall(toolCall):
      let parts = toolCall.id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
      let callID = String(parts[0])
      var object: [String: JSONValue] = [
        "type": .string("function_call"),
        "call_id": .string(callID),
        "name": .string(toolCall.name),
        "arguments": .string(jsonString(toolCall.arguments)),
      ]
      if parts.count == 2 {
        object["id"] = .string(String(parts[1]))
      }
      return .object(object)

    case let .reasoning(reasoning):
      let summaryItems: [JSONValue]
      if let summary = reasoning.summary {
        summaryItems = [
          .object([
            "type": .string("summary_text"),
            "text": .string(summary),
          ])
        ]
      } else {
        summaryItems = []
      }

      var object: [String: JSONValue] = [
        "type": .string("reasoning"),
        "summary": .array(summaryItems),
      ]
      if let reasoningID = reasoning.id {
        object["id"] = .string(reasoningID)
      }
      if let signature = reasoning.signature {
        object["encrypted_content"] = .string(signature)
      }
      return .object(object)
    }
  }
}

private func encodeToolResult(_ toolResult: ToolResultMessage) throws -> [JSONValue] {
  let outputText = toolResult.content.compactMap { part -> String? in
    guard case let .text(text) = part else { return nil }
    return text.text
  }.joined(separator: "\n")

  let callID = String(toolResult.toolCallID.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
  var items: [JSONValue] = [
    .object([
      "type": .string("function_call_output"),
      "call_id": .string(callID),
      "output": .string(outputText.isEmpty ? "(no output)" : outputText),
    ])
  ]

  let mediaParts = try toolResult.content.compactMap { part -> JSONValue? in
    guard case let .media(media) = part else { return nil }
    return try encodeMediaPart(media)
  }

  if !mediaParts.isEmpty {
    items.append(.object([
      "role": .string("user"),
      "content": .array([
        .object([
          "type": .string("input_text"),
          "text": .string("Attached media from tool result:"),
        ])
      ] + mediaParts),
    ]))
  }

  return items
}

private func encodeMediaPart(_ media: MediaPart) throws -> JSONValue {
  let type = media.kind == .image ? "input_image" : "input_file"

  switch media.source {
  case let .data(data):
    if media.kind == .image {
      return .object([
        "type": .string(type),
        "image_url": .string("data:\(media.mimeType);base64,\(data.base64EncodedString())"),
      ])
    } else {
      return .object([
        "type": .string(type),
        "file_data": .string("data:\(media.mimeType);base64,\(data.base64EncodedString())"),
      ])
    }

  case let .remoteURL(url):
    if media.kind == .image {
      return .object([
        "type": .string(type),
        "image_url": .string(url.absoluteString),
      ])
    } else {
      return .object([
        "type": .string(type),
        "file_url": .string(url.absoluteString),
      ])
    }

  case let .fileReference(reference):
    return .object([
      "type": .string("input_file"),
      "file_id": .string(reference.id),
    ])
  }
}

private func encodeTool(_ tool: Tool) -> JSONValue {
  .object([
    "type": .string("function"),
    "name": .string(tool.name),
    "description": .string(tool.description),
    "parameters": tool.inputSchema,
    "strict": .bool(false),
  ])
}

private func summaryText(from value: JSONValue?) -> String? {
  guard let array = value?.array else { return nil }
  let parts = array.compactMap { item -> String? in
    guard let object = item.object else { return nil }
    return object["text"]?.stringValue
  }
  return parts.isEmpty ? nil : parts.joined(separator: "\n")
}

private func parseEventJSON(_ text: String) throws -> JSONValue? {
  guard !text.isEmpty, text != "[DONE]" else { return nil }
  let data = Data(text.utf8)
  let object = try JSONSerialization.jsonObject(with: data)
  return try JSONValue.fromAny(object)
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
