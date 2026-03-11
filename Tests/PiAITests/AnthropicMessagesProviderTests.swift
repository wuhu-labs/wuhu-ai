import Foundation
import PiAI
import Testing

struct AnthropicMessagesProviderTests {
  @Test func streamsAnthropicSSEIntoMessageEvents() async throws {
    let apiKey = "ak-test"

    let http = MockHTTPClient(sseHandler: { request in
      #expect(request.url.absoluteString == "https://api.anthropic.com/v1/messages")
      let headers = normalizedHeaders(request)
      #expect(headers["x-api-key"] == apiKey)
      #expect(headers["accept"] == "text/event-stream")

      return AsyncThrowingStream { continuation in
        continuation.yield(.init(event: "content_block_delta", data: #"{"delta":{"type":"text_delta","text":"Hello"}}"#))
        continuation.yield(.init(event: "message_stop", data: #"{}"#))
        continuation.finish()
      }
    })

    let provider = AnthropicMessagesProvider(http: http)
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

    let http = MockHTTPClient(sseHandler: { _ in
      AsyncThrowingStream { continuation in
        // message_start with usage
        continuation.yield(.init(
          event: "message_start",
          data: #"{"type":"message_start","message":{"usage":{"input_tokens":100,"cache_creation_input_tokens":20,"cache_read_input_tokens":10,"output_tokens":0}}}"#,
        ))
        continuation.yield(.init(
          event: "content_block_delta",
          data: #"{"delta":{"type":"text_delta","text":"Hi"}}"#,
        ))
        // message_delta with output usage
        continuation.yield(.init(
          event: "message_delta",
          data: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#,
        ))
        continuation.yield(.init(
          event: "message_stop",
          data: #"{}"#,
        ))
        continuation.finish()
      }
    })

    let provider = AnthropicMessagesProvider(http: http)
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

    let http = MockHTTPClient(sseHandler: { request in
      let body = try #require(request.body)
      let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
      let dict = try #require(obj)

      let cacheControl = dict["cache_control"] as? [String: Any]
      #expect(cacheControl?["type"] as? String == "ephemeral")

      return AsyncThrowingStream { continuation in
        continuation.yield(.init(event: "message_stop", data: #"{}"#))
        continuation.finish()
      }
    })

    let provider = AnthropicMessagesProvider(http: http)
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

    let http = MockHTTPClient(sseHandler: { request in
      let body = try #require(request.body)
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

      return AsyncThrowingStream { continuation in
        continuation.yield(.init(event: "message_stop", data: #"{}"#))
        continuation.finish()
      }
    })

    let provider = AnthropicMessagesProvider(http: http)
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
  @Test func parsesThinkingBlocksFromSSE() async throws {
    let apiKey = "ak-test"

    let http = MockHTTPClient(sseHandler: { _ in
      AsyncThrowingStream { continuation in
        // Thinking block start
        continuation.yield(.init(
          event: "content_block_start",
          data: #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
        ))
        // Thinking delta
        continuation.yield(.init(
          event: "content_block_delta",
          data: #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me think about this..."}}"#,
        ))
        continuation.yield(.init(
          event: "content_block_delta",
          data: #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" The answer is 42."}}"#,
        ))
        // Thinking block stop with signature
        continuation.yield(.init(
          event: "content_block_stop",
          data: #"{"type":"content_block_stop","index":0,"content_block":{"type":"thinking","thinking":"Let me think about this... The answer is 42.","signature":"sig_abc123"}}"#,
        ))
        // Text block
        continuation.yield(.init(
          event: "content_block_start",
          data: #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
        ))
        continuation.yield(.init(
          event: "content_block_delta",
          data: #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"The answer is 42."}}"#,
        ))
        continuation.yield(.init(
          event: "content_block_stop",
          data: #"{"type":"content_block_stop","index":1}"#,
        ))
        continuation.yield(.init(
          event: "message_delta",
          data: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":50}}"#,
        ))
        continuation.yield(.init(event: "message_stop", data: #"{}"#))
        continuation.finish()
      }
    })

    let provider = AnthropicMessagesProvider(http: http)
    let model = Model(id: "claude-opus-4-5-20251101", provider: .anthropic)
    let context = Context(systemPrompt: "Test", messages: [.user("Think")])

    let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: apiKey))
    var done: AssistantMessage?
    for try await event in stream {
      if case let .done(message) = event { done = message }
    }

    let message = try #require(done)
    #expect(message.content.count == 2)

    // First block should be reasoning (thinking)
    guard case let .reasoning(reasoning) = message.content[0] else {
      Issue.record("Expected reasoning block, got \(message.content[0])")
      return
    }
    #expect(reasoning.encryptedContent == "sig_abc123")
    #expect(reasoning.summary == [.string("Let me think about this... The answer is 42.")])

    // Second block should be text
    guard case let .text(text) = message.content[1] else {
      Issue.record("Expected text block, got \(message.content[1])")
      return
    }
    #expect(text.text == "The answer is 42.")
  }

  @Test func serializesThinkingBlocksInRequestBody() async throws {
    let apiKey = "ak-test"

    let http = MockHTTPClient(sseHandler: { request in
      let body = try #require(request.body)
      let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
      let messages = try #require(json["messages"] as? [[String: Any]])

      // The assistant message should contain a thinking block
      let assistantMsg = try #require(messages.first(where: { $0["role"] as? String == "assistant" }))
      let content = try #require(assistantMsg["content"] as? [[String: Any]])

      let thinkingBlock = content.first(where: { $0["type"] as? String == "thinking" })
      #expect(thinkingBlock != nil)
      #expect(thinkingBlock?["thinking"] as? String == "I should use the calculator.")
      #expect(thinkingBlock?["signature"] as? String == "sig_xyz789")

      let toolUseBlock = content.first(where: { $0["type"] as? String == "tool_use" })
      #expect(toolUseBlock != nil)
      #expect(toolUseBlock?["name"] as? String == "calculate")

      return AsyncThrowingStream { continuation in
        continuation.yield(.init(event: "message_stop", data: #"{}"#))
        continuation.finish()
      }
    })

    let provider = AnthropicMessagesProvider(http: http)
    let model = Model(id: "claude-opus-4-5-20251101", provider: .anthropic)

    let assistant = AssistantMessage(
      provider: .anthropic,
      model: model.id,
      content: [
        .reasoning(.init(
          id: UUID().uuidString,
          encryptedContent: "sig_xyz789",
          summary: [.string("I should use the calculator.")]
        )),
        .toolCall(.init(id: "toolu_123", name: "calculate", arguments: .object(["expr": .string("2+2")]))),
      ],
      stopReason: .toolUse
    )

    let context = Context(
      systemPrompt: "You are helpful.",
      messages: [
        .user("What is 2+2?"),
        .assistant(assistant),
        .toolResult(.init(toolCallId: "toolu_123", toolName: "calculate", content: [.text("4")])),
      ]
    )

    let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: apiKey))
    for try await _ in stream {}
  }

  @Test func skipsThinkingBlocksWithoutSignature() async throws {
    let apiKey = "ak-test"

    let http = MockHTTPClient(sseHandler: { request in
      let body = try #require(request.body)
      let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
      let messages = try #require(json["messages"] as? [[String: Any]])

      let assistantMsg = try #require(messages.first(where: { $0["role"] as? String == "assistant" }))
      let content = try #require(assistantMsg["content"] as? [[String: Any]])

      // Should NOT contain a thinking block (no signature)
      let thinkingBlock = content.first(where: { $0["type"] as? String == "thinking" })
      #expect(thinkingBlock == nil)

      // Should still contain the text block
      let textBlock = content.first(where: { $0["type"] as? String == "text" })
      #expect(textBlock?["text"] as? String == "The answer is 4.")

      return AsyncThrowingStream { continuation in
        continuation.yield(.init(event: "message_stop", data: #"{}"#))
        continuation.finish()
      }
    })

    let provider = AnthropicMessagesProvider(http: http)
    let model = Model(id: "claude-opus-4-5-20251101", provider: .anthropic)

    // Reasoning block with no signature should be skipped
    let assistant = AssistantMessage(
      provider: .anthropic,
      model: model.id,
      content: [
        .reasoning(.init(id: UUID().uuidString, encryptedContent: nil, summary: [.string("thinking text")])),
        .text("The answer is 4."),
      ]
    )

    let context = Context(
      systemPrompt: "Test",
      messages: [
        .user("What is 2+2?"),
        .assistant(assistant),
        .user("Thanks"),
      ]
    )

    let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: apiKey))
    for try await _ in stream {}
  }
}

private func normalizedHeaders(_ request: HTTPRequest) -> [String: String] {
  Dictionary(
    uniqueKeysWithValues: request.headers.map { key, values in
      (key.lowercased(), values.joined(separator: ", "))
    },
  )
}
