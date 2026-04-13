import Foundation
import Testing
import WuhuAI

struct OpenAIResponsesProviderTests {
  @Test func streamsResponsesSSEIntoMessageEvents() async throws {
    let apiKey = "sk-test"

    let fetch = MockFetchClient(handler: { request in
      #expect(request.url.absoluteString == "https://api.openai.com/v1/responses")
      let headers = normalizedHeaders(request)
      #expect(headers["authorization"] == "Bearer \(apiKey)")
      #expect(headers["accept"] == "text/event-stream")

      return sseResponse([
        .init(data: #"{"type":"response.output_text.delta","delta":"Hello"}"#),
        .init(data: #"{"type":"response.output_item.done","item":{"content":[{"type":"output_text","text":"Hello"}]}}"#),
        .init(data: #"{"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}}"#),
      ])
    })

    let provider = OpenAIResponsesProvider(fetch: fetch.client)
    let model = Model(id: "gpt-4.1-mini", provider: .openai)
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
    #expect(message.usage == Usage(inputTokens: 1, outputTokens: 2, totalTokens: 3))
  }

  @Test func replaysReasoningItemsInRequestBody() async throws {
    let apiKey = "sk-test"

    let fetch = MockFetchClient(handler: { request in
      let body = try #require(try await bodyData(request))
      let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

      #expect(json["store"] as? Bool == false)

      let input = try #require(json["input"] as? [[String: Any]])
      let reasoning = input.first(where: { ($0["type"] as? String) == "reasoning" })
      #expect(reasoning?["id"] as? String == "rsn_1")
      #expect(reasoning?["encrypted_content"] as? String == "enc_1")
      #expect((reasoning?["summary"] as? [Any]) != nil)

      return sseResponse([])
    })

    let provider = OpenAIResponsesProvider(fetch: fetch.client)
    let model = Model(id: "gpt-5.2-codex", provider: .openai)

    let assistant = AssistantMessage(provider: .openai, model: model.id, content: [
      .reasoning(.init(id: "rsn_1", encryptedContent: "enc_1")),
      .toolCall(.init(id: "call_1|item_1", name: "read", arguments: .object([:]))),
    ])

    let context = Context(systemPrompt: nil, messages: [
      .user("Run a tool"),
      .assistant(assistant),
      .toolResult(.init(toolCallId: "call_1|item_1", toolName: "read", content: [.text(.init(text: "ok"))])),
      .user("Continue"),
    ])

    let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: apiKey, reasoningEffort: .low))
    for try await _ in stream {}
  }

  @Test func serializesToolCallArgumentsWithSortedKeys() async throws {
    let apiKey = "sk-test"

    // Verify that tool call arguments are serialized with deterministic (sorted)
    // key ordering. Before the fix, jsonString() called JSONSerialization without
    // .sortedKeys, causing non-deterministic argument strings that broke OpenAI's
    // prompt cache prefix matching across requests.
    final class BodyCollector: @unchecked Sendable {
      var body: Data?
      func capture(_ data: Data) { body = data }
    }
    let collector = BodyCollector()

    let fetch = MockFetchClient(handler: { request in
      if let body = try await bodyData(request) {
        collector.capture(body)
      }
      return sseResponse([])
    })

    let provider = OpenAIResponsesProvider(fetch: fetch.client)
    let model = Model(id: "gpt-5.2", provider: .openai)

    let assistant = AssistantMessage(provider: .openai, model: model.id, content: [
      .toolCall(.init(
        id: "call_1",
        name: "bash",
        arguments: .object([
          "command": .string("echo hello"),
          "timeout": .number(30),
          "mount": .string("primary"),
          "zebra": .string("last"),
          "alpha": .string("first"),
        ])
      )),
    ], stopReason: .toolUse)

    let context = Context(systemPrompt: "test", messages: [
      .user("Run a command"),
      .assistant(assistant),
      .toolResult(.init(toolCallId: "call_1", toolName: "bash", content: [.text("hello\n")])),
      .user("Again"),
    ])

    let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: apiKey))
    for try await _ in stream {}

    let body = try #require(collector.body)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let input = try #require(json["input"] as? [[String: Any]])
    let funcCall = try #require(input.first(where: { ($0["type"] as? String) == "function_call" }))
    let argsString = try #require(funcCall["arguments"] as? String)

    // Verify sorted order: "alpha" < "command" < "mount" < "timeout" < "zebra"
    let alphaIdx = try #require(argsString.range(of: "\"alpha\"")).lowerBound
    let commandIdx = try #require(argsString.range(of: "\"command\"")).lowerBound
    let mountIdx = try #require(argsString.range(of: "\"mount\"")).lowerBound
    let timeoutIdx = try #require(argsString.range(of: "\"timeout\"")).lowerBound
    let zebraIdx = try #require(argsString.range(of: "\"zebra\"")).lowerBound
    #expect(alphaIdx < commandIdx)
    #expect(commandIdx < mountIdx)
    #expect(mountIdx < timeoutIdx)
    #expect(timeoutIdx < zebraIdx)
  }
}
