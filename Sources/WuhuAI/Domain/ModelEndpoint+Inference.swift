import Dependencies
import Fetch
import FetchSSE
import Foundation
import HTTPTypes
import JSONValue

// MARK: - ModelInference

public struct ModelInference: Hashable, Sendable {
  public var message: AssistantMessage
  public var metadata: AssistantMessageMetadata

  public init(
    message: AssistantMessage,
    metadata: AssistantMessageMetadata,
  ) {
    self.message = message
    self.metadata = metadata
  }
}

// MARK: - ModelInferenceError

public enum ModelInferenceError: Error, Equatable, Sendable {
  case missingFinalMessage
}

// MARK: - ModelEndpoint Inference

extension ModelEndpoint {
  public func stream(
    context: Context,
    options: RequestOptions = RequestOptions(),
    mediaResolver: (any MediaResolver)? = nil,
  ) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
    @Dependency(\.fetch) var dependencyFetchClient
    let fetchClient = dependencyFetchClient

    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let (url, requestHeaders, requestBody) = try await buildRequest(
            endpoint: self,
            context: context,
            options: options,
            mediaResolver: mediaResolver,
          )

          var body = requestBody
          self.modifyBody(&body, options: options)

          let request = Request(
            url: url,
            method: .post,
            headers: makeHTTPFields(
              from: requestHeaders,
              extra: self.modifyHeaders(options),
            ),
            body: .string(JSONValue.object(body).jsonString(sortedKeys: false), encoding: .utf8),
          )

          let response = try await fetchClient.fetch(request)
          guard (200 ..< 300).contains(response.status.code) else {
            throw FetchError.unexpectedStatus(response.status)
          }
          let sseStream = response.sse().mapWuhuAIEvents()
          let eventStream = parseStream(
            dialect: self.dialect,
            sse: sseStream,
            providerID: self.providerID,
            model: self.model,
          )

          for try await event in eventStream {
            switch event {
            case let .done(message, metadata):
              var normalizedMessage = message
              self.normalizeOutput(&normalizedMessage)
              continuation.yield(.done(normalizedMessage, metadata))
            default:
              continuation.yield(event)
            }
          }
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

  public func infer(
    context: Context,
    options: RequestOptions = RequestOptions(),
    mediaResolver: (any MediaResolver)? = nil,
  ) async throws -> ModelInference {
    let eventStream = self.stream(
      context: context,
      options: options,
      mediaResolver: mediaResolver,
    )

    for try await event in eventStream {
      if case let .done(message, metadata) = event {
        return ModelInference(message: message, metadata: metadata)
      }
    }

    throw ModelInferenceError.missingFinalMessage
  }
}

// MARK: - Request Building

private func buildRequest(
  endpoint: any ModelEndpoint,
  context: Context,
  options: RequestOptions,
  mediaResolver: (any MediaResolver)?,
) async throws -> (URL, [String: String], [String: JSONValue]) {
  switch endpoint.dialect {
  case .chatCompletions:
    return try await buildChatCompletionsRequest(
      model: endpoint.model,
      baseURL: endpoint.baseURL,
      context: context,
      options: options,
      mediaResolver: mediaResolver,
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
  sse: AsyncThrowingStream<SSEEvent, any Error>,
  providerID: String,
  model: String,
) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
  switch dialect {
  case .chatCompletions:
    parseChatCompletionsStream(sse, providerID: providerID, model: model)
  case .responses:
    parseResponsesStream(sse, providerID: providerID, model: model)
  case .anthropic:
    parseAnthropicStream(sse, providerID: providerID, model: model)
  case .gemini:
    parseGeminiStream(sse, providerID: providerID, model: model)
  }
}

// MARK: - SSE Bridging

private extension AsyncThrowingStream where Element == FetchSSE.SSEEvent, Failure == any Error {
  func mapWuhuAIEvents() -> AsyncThrowingStream<WuhuAI.SSEEvent, any Error> {
    AsyncThrowingStream<WuhuAI.SSEEvent, any Error> { continuation in
      let task = Task {
        do {
          for try await event in self {
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

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
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
