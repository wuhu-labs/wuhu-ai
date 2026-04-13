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

  @Test func streamsAnthropicThinkingIntoReasoningBlocks() async throws {
    let apiKey = "ak-test"

    let fetch = MockFetchClient(handler: { _ in
      sseResponse([
        .init(
          event: "content_block_start",
          data: #"{"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
        ),
        .init(
          event: "content_block_delta",
          data: #"{"delta":{"type":"thinking_delta","thinking":"I should think first."}}"#,
        ),
        .init(
          event: "content_block_delta",
          data: #"{"delta":{"type":"signature_delta","signature":"sig_1"}}"#,
        ),
        .init(event: "content_block_stop", data: #"{}"#),
        .init(
          event: "content_block_start",
          data: #"{"content_block":{"type":"text","text":""}}"#,
        ),
        .init(
          event: "content_block_delta",
          data: #"{"delta":{"type":"text_delta","text":"Done."}}"#,
        ),
        .init(
          event: "message_delta",
          data: #"{"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}"#,
        ),
        .init(event: "message_stop", data: #"{}"#),
      ])
    })

    let provider = AnthropicMessagesProvider(fetch: fetch.client)
    let model = Model(id: "claude-opus-4-6", provider: .anthropic)
    let context = Context(messages: [.user("Think")])

    let stream = try await provider.stream(
      model: model,
      context: context,
      options: .init(apiKey: apiKey, anthropicThinking: .init(mode: .adaptive)),
    )

    var done: AssistantMessage?
    for try await event in stream {
      if case let .done(message) = event {
        done = message
      }
    }

    let message = try #require(done)
    #expect(message.content.count == 2)

    guard case let .reasoning(reasoning) = try #require(message.content.first) else {
      Issue.record("Expected first content block to be reasoning")
      return
    }
    #expect(reasoning.text == "I should think first.")
    #expect(reasoning.signature == "sig_1")

    guard case let .text(text) = try #require(message.content.last) else {
      Issue.record("Expected final content block to be text")
      return
    }
    #expect(text.text == "Done.")
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

  @Test func manualThinkingAddsThinkingBodyAndInterleavedBetaHeader() async throws {
    let apiKey = "ak-test"

    let fetch = MockFetchClient(handler: { request in
      let headers = normalizedHeaders(request)
      #expect(headers["anthropic-beta"]?.contains("interleaved-thinking-2025-05-14") == true)

      let body = try #require(try await bodyData(request))
      let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
      let thinking = try #require(json["thinking"] as? [String: Any])
      #expect(thinking["type"] as? String == "enabled")
      #expect(thinking["budget_tokens"] as? Int == 2000)
      #expect(thinking["display"] as? String == "summarized")
      #expect(json["output_config"] == nil)

      return sseResponse([])
    })

    let provider = AnthropicMessagesProvider(fetch: fetch.client)
    let model = Model(id: "claude-opus-4-5", provider: .anthropic)
    let context = Context(messages: [.user("Think before act")])

    let stream = try await provider.stream(
      model: model,
      context: context,
      options: .init(apiKey: apiKey, anthropicThinking: .init(mode: .manual, budgetTokens: 2000)),
    )
    for try await _ in stream {}
  }

  @Test func bridgesReasoningEffortToAdaptiveThinkingOnOpus46() async throws {
    let apiKey = "ak-test"

    let fetch = MockFetchClient(handler: { request in
      let headers = normalizedHeaders(request)
      #expect(headers["anthropic-beta"]?.contains("interleaved-thinking-2025-05-14") == true)

      let body = try #require(try await bodyData(request))
      let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
      let thinking = try #require(json["thinking"] as? [String: Any])
      let outputConfig = try #require(json["output_config"] as? [String: Any])

      #expect(thinking["type"] as? String == "adaptive")
      #expect(thinking["display"] as? String == "summarized")
      #expect(outputConfig["effort"] as? String == "medium")

      return sseResponse([])
    })

    let provider = AnthropicMessagesProvider(fetch: fetch.client)
    let model = Model(id: "claude-opus-4-6", provider: .anthropic)
    let context = Context(messages: [.user("Think before act")])

    let stream = try await provider.stream(
      model: model,
      context: context,
      options: .init(apiKey: apiKey, reasoningEffort: .minimal),
    )
    for try await _ in stream {}
  }

  @Test func replaysAnthropicReasoningItemsInRequestBody() async throws {
    let apiKey = "ak-test"

    let fetch = MockFetchClient(handler: { request in
      let body = try #require(try await bodyData(request))
      let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
      let messages = try #require(json["messages"] as? [[String: Any]])
      let assistant = try #require(messages.first(where: { ($0["role"] as? String) == "assistant" }))
      let content = try #require(assistant["content"] as? [[String: Any]])

      let thinking = try #require(content.first(where: { ($0["type"] as? String) == "thinking" }))
      #expect(thinking["thinking"] as? String == "I should inspect the tool result.")
      #expect(thinking["signature"] as? String == "sig_1")

      let redacted = try #require(content.first(where: { ($0["type"] as? String) == "redacted_thinking" }))
      #expect(redacted["data"] as? String == "redacted_blob")

      return sseResponse([])
    })

    let provider = AnthropicMessagesProvider(fetch: fetch.client)
    let model = Model(id: "claude-opus-4-5", provider: .anthropic)

    let assistant = AssistantMessage(provider: .anthropic, model: model.id, content: [
      .reasoning(.init(id: "rsn_1", text: "I should inspect the tool result.", signature: "sig_1")),
      .reasoning(.init(id: "rsn_2", redactedData: "redacted_blob")),
      .toolCall(.init(id: "tool_1", name: "read_file", arguments: .object([:])))
    ])

    let context = Context(messages: [
      .user("Think before act"),
      .assistant(assistant),
      .toolResult(.init(toolCallId: "tool_1", toolName: "read_file", content: [.text("ok")]))
    ])

    let stream = try await provider.stream(
      model: model,
      context: context,
      options: .init(apiKey: apiKey, anthropicThinking: .init(mode: .manual, budgetTokens: 2000)),
    )
    for try await _ in stream {}
  }
}
