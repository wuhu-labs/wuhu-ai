import Foundation
import Testing
import WuhuAI

struct AnthropicMessagesProviderTests {
  @Test func streamsAnthropicSSEIntoMessageEvents() async throws {
    let apiKey = "ak-test"

    let fetch = MockFetchClient(handler: { request in
      #expect(request.url.absoluteString == "https://api.anthropic.com/v1/messages")
      let headers = normalizedHeaders(request)
      #expect(headers["x-api-key"] == apiKey)
      #expect(headers["accept"] == "text/event-stream")

      return sseResponse([
        .init(event: "content_block_delta", data: #"{"delta":{"type":"text_delta","text":"Hello"}}"#),
        .init(event: "message_stop", data: #"{}"#),
      ])
    })

    let provider = AnthropicMessagesProvider(fetch: fetch.client)
    let model = Model(id: "claude-sonnet-4-5", provider: .anthropic)
    let context = Context(systemPrompt: "You are a helpful assistant.", messages: [
      .user("Say hello"),
    ])

    let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: apiKey))
    var done: AssistantMessage?
    for try await event in stream {
      if case let .done(message) = event {
        done = message
      }
    }

    let message = try #require(done)
    #expect(message.content == [.text(.init(text: "Hello"))])
  }

  @Test func parsesUsageFromSSEEvents() async throws {
    let apiKey = "ak-test"

    let fetch = MockFetchClient(handler: { _ in
      sseResponse([
        .init(
          event: "message_start",
          data: #"{"type":"message_start","message":{"usage":{"input_tokens":100,"cache_creation_input_tokens":20,"cache_read_input_tokens":10,"output_tokens":0}}}"#,
        ),
        .init(
          event: "content_block_delta",
          data: #"{"delta":{"type":"text_delta","text":"Hi"}}"#,
        ),
        .init(
          event: "message_delta",
          data: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#,
        ),
        .init(
          event: "message_stop",
          data: #"{}"#,
        ),
      ])
    })

    let provider = AnthropicMessagesProvider(fetch: fetch.client)
    let model = Model(id: "claude-sonnet-4-5", provider: .anthropic)
    let context = Context(systemPrompt: "Test", messages: [.user("Hi")])

    let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: apiKey))
    var done: AssistantMessage?
    for try await event in stream {
      if case let .done(message) = event {
        done = message
      }
    }

    let message = try #require(done)
    let usage = try #require(message.usage)
    #expect(usage.inputTokens == 130) // 100 + 20 + 10
    #expect(usage.outputTokens == 42)
    #expect(usage.totalTokens == 172) // 130 + 42
  }

  @Test func automaticPromptCachingAddsTopLevelCacheControl() async throws {
    let apiKey = "ak-test"

    let fetch = MockFetchClient(handler: { request in
      let body = try #require(try await bodyData(request))
      let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
      let dict = try #require(obj)

      let cacheControl = dict["cache_control"] as? [String: Any]
      #expect(cacheControl?["type"] as? String == "ephemeral")

      return sseResponse([
        .init(event: "message_stop", data: #"{}"#),
      ])
    })

    let provider = AnthropicMessagesProvider(fetch: fetch.client)
    let model = Model(id: "claude-sonnet-4-5", provider: .anthropic)
    let context = Context(systemPrompt: "You are a helpful assistant.", messages: [
      .user("Say hello"),
    ])

    let stream = try await provider.stream(
      model: model,
      context: context,
      options: .init(apiKey: apiKey, anthropicPromptCaching: .init(mode: .automatic)),
    )
    for try await _ in stream {}
  }

  @Test func explicitPromptCachingAddsBlockBreakpoints() async throws {
    let apiKey = "ak-test"

    let fetch = MockFetchClient(handler: { request in
      let body = try #require(try await bodyData(request))
      let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
      let dict = try #require(obj)

      let system = dict["system"] as? [[String: Any]]
      #expect(system?.first?["type"] as? String == "text")
      #expect((system?.first?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

      let messages = dict["messages"] as? [[String: Any]]
      let first = try #require(messages?.first)
      let content = first["content"] as? [[String: Any]]
      let last = try #require(content?.last)
      #expect((last["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

      return sseResponse([
        .init(event: "message_stop", data: #"{}"#),
      ])
    })

    let provider = AnthropicMessagesProvider(fetch: fetch.client)
    let model = Model(id: "claude-sonnet-4-5", provider: .anthropic)
    let context = Context(systemPrompt: "You are a helpful assistant.", messages: [
      .user("Say hello"),
    ])

    let stream = try await provider.stream(
      model: model,
      context: context,
      options: .init(apiKey: apiKey, anthropicPromptCaching: .init(mode: .explicitBreakpoints)),
    )
    for try await _ in stream {}
  }
}
