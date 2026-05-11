import Fetch
import FetchSSE
import Foundation
import HTTPTypes
@testable import WuhuAI
import JSONValue

// MARK: - Inference Engine

/// Send a single inference request through the recording fetch client
/// and return the final assistant message with metadata.
func infer(
  endpoint: any ModelEndpoint,
  context: Context,
  options: RequestOptions = RequestOptions(),
  recording: RecordingContext,
) async throws -> (AssistantMessage, AssistantMessageMetadata) {
  // 1. Build the dialect-specific request.
  let (url, reqHeaders, reqBody) = try await buildRequest(
    endpoint: endpoint,
    context: context,
    options: options,
  )

  // 2. Apply endpoint-specific modifications.
  var body = reqBody
  endpoint.modifyBody(&body, options: options)
  let extraHeaders = endpoint.modifyHeaders(options)

  // 3. Convert to wuhu-fetch types.
  let fetchHeaders = makeHTTPFields(from: reqHeaders, extra: extraHeaders)
  let jsonString = JSONValue.object(body).jsonString(sortedKeys: false)
  let fetchBody = Body.string(jsonString, encoding: .utf8)

  let request = Request(
    url: url,
    method: .post,
    headers: fetchHeaders,
    body: fetchBody,
  )

  // 4. Send through the recording fetch client.
  let response = try await recording.fetchClient.fetch(request)

  // 5. Parse SSE stream.
  let fetchSSEStream = response.sse()

  // Bridge FetchSSE.SSEEvent → WuhuAI.SSEEvent
  let jiuziSSEStream: AsyncThrowingStream<WuhuAI.SSEEvent, any Error> =
    AsyncThrowingStream { continuation in
      Task {
        do {
          for try await event in fetchSSEStream {
            continuation.yield(WuhuAI.SSEEvent(
              event: event.event,
              data: event.data,
              id: event.id,
              retry: event.retry,
            ))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }

  // 6. Parse domain events based on dialect.
  let eventStream = parseStream(
    dialect: endpoint.dialect,
    sse: jiuziSSEStream,
    providerID: endpoint.providerID,
    model: endpoint.model,
  )

  // 7. Collect events and return the final message with metadata.
  var finalMessage: AssistantMessage?
  var finalMetadata: AssistantMessageMetadata?
  for try await event in eventStream {
    switch event {
    case let .done(msg, metadata):
      finalMessage = msg
      finalMetadata = metadata
    default:
      break
    }
  }

  guard var result = finalMessage, let metadata = finalMetadata else {
    throw IntegrationTestError.noRecordingsFound("No final message received from stream")
  }

  // 8. Apply output normalization.
  endpoint.normalizeOutput(&result)
  return (result, metadata)
}

// MARK: - Request Building

private func buildRequest(
  endpoint: any ModelEndpoint,
  context: Context,
  options: RequestOptions,
) async throws -> (URL, [String: String], [String: JSONValue]) {
  switch endpoint.dialect {
  case .chatCompletions:
    return try await buildChatCompletionsRequest(
      model: endpoint.model,
      baseURL: endpoint.baseURL,
      context: context,
      options: options,
      mediaResolver: nil,
    )

  case .responses:
    let isCodex = endpoint.providerID == "openai-codex"
    return buildResponsesRequest(
      model: endpoint.model,
      baseURL: endpoint.baseURL,
      context: context,
      options: options,
      isCodex: isCodex,
    )

  case .anthropic:
    return buildAnthropicRequest(
      model: endpoint.model,
      baseURL: endpoint.baseURL,
      context: context,
      options: options,
    )

  case .gemini:
    return buildGeminiRequest(
      model: endpoint.model,
      baseURL: endpoint.baseURL,
      context: context,
      options: options,
    )
  }
}

// MARK: - Stream Parsing

private func parseStream(
  dialect: Dialect,
  sse: AsyncThrowingStream<WuhuAI.SSEEvent, any Error>,
  providerID: String,
  model: String,
) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
  switch dialect {
  case .chatCompletions:
    return parseChatCompletionsStream(sse, providerID: providerID, model: model)
  case .responses:
    return parseResponsesStream(sse, providerID: providerID, model: model)
  case .anthropic:
    return parseAnthropicStream(sse, providerID: providerID, model: model)
  case .gemini:
    return parseGeminiStream(sse, providerID: providerID, model: model)
  }
}

// MARK: - HTTPFields Construction

private func makeHTTPFields(from headers: [String: String], extra: [String: String]) -> HTTPFields {
  var fields = HTTPFields()
  for (key, value) in headers {
    if let name = HTTPField.Name(key) {
      fields[name] = value
    }
  }
  for (key, value) in extra {
    if let name = HTTPField.Name(key) {
      fields[name] = value
    }
  }
  return fields
}
