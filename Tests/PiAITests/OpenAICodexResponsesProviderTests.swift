import Foundation
import Testing
import WuhuAI

struct OpenAICodexResponsesProviderTests {
  @Test func streamsSSEEventsIntoMessageEvents() async throws {
    let token = makeTestJWT(accountId: "acc_test")

    let fetch = MockFetchClient(handler: { request in
      #expect(request.url.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
      let headers = normalizedHeaders(request)
      #expect(headers["authorization"] == "Bearer \(token)")
      #expect(headers["chatgpt-account-id"] == "acc_test")
      #expect(headers["openai-beta"] == "responses=experimental")
      #expect(headers["originator"] == "pi")
      #expect(headers["accept"] == "text/event-stream")
      #expect(headers["x-api-key"] == nil)

      return sseResponse([
        .init(data: #"{"type":"response.output_item.added","item":{"type":"message","id":"msg_1","role":"assistant","status":"in_progress","content":[]}}"#),
        .init(data: #"{"type":"response.content_part.added","part":{"type":"output_text","text":""}}"#),
        .init(data: #"{"type":"response.output_text.delta","delta":"Hello"}"#),
        .init(data: #"{"type":"response.output_item.done","item":{"type":"message","id":"msg_1","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello"}]}}"#),
        .init(data: #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":5,"output_tokens":3,"total_tokens":8,"input_tokens_details":{"cached_tokens":0}}}}"#),
      ])
    })

    let provider = OpenAICodexResponsesProvider(fetch: fetch.client)
    let model = Model(id: "gpt-5.1-codex", provider: .openaiCodex)
    let context = Context(systemPrompt: "You are a helpful assistant.", messages: [
      .user("Say hello"),
    ])

    let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: token))
    var sawTextDelta = false
    var sawDone = false

    for try await event in stream {
      switch event {
      case let .textDelta(delta, _):
        if delta == "Hello" { sawTextDelta = true }
      case let .done(message):
        sawDone = true
        #expect(message.content == [.text(.init(text: "Hello"))])
        #expect(message.usage == Usage(inputTokens: 5, outputTokens: 3, totalTokens: 8))
      default:
        break
      }
    }

    #expect(sawTextDelta)
    #expect(sawDone)
  }

  @Test func setsSessionHeadersAndPromptCacheKeyWhenSessionIdProvided() async throws {
    let token = makeTestJWT(accountId: "acc_test")
    let sessionId = "test-session-123"

    let fetch = MockFetchClient(handler: { request in
      let headers = normalizedHeaders(request)
      #expect(headers["conversation_id"] == sessionId)
      #expect(headers["session_id"] == sessionId)

      let body = try #require(try await bodyData(request))
      let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
      let promptCacheKey = json?["prompt_cache_key"] as? String
      let retention = json?["prompt_cache_retention"] as? String
      #expect(promptCacheKey == sessionId)
      #expect(retention == "in-memory")

      return sseResponse([])
    })

    let provider = OpenAICodexResponsesProvider(fetch: fetch.client)
    let model = Model(id: "gpt-5.1-codex", provider: .openaiCodex)
    let context = Context(systemPrompt: "You are a helpful assistant.", messages: [
      .user("Say hello"),
    ])

    _ = try await provider.stream(
      model: model,
      context: context,
      options: .init(apiKey: token, sessionId: sessionId),
    )
  }

  @Test func includesReasoningEffortAndClampsUnsupportedValues() async throws {
    let token = makeTestJWT(accountId: "acc_test")

    do {
      let fetch = MockFetchClient(handler: { request in
        let body = try #require(try await bodyData(request))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "low")
        #expect(reasoning["summary"] as? String == "auto")
        return sseResponse([])
      })

      let provider = OpenAICodexResponsesProvider(fetch: fetch.client)
      let model = Model(id: "gpt-5.2-codex", provider: .openaiCodex)
      let context = Context(systemPrompt: nil, messages: [.user("Hi")])
      _ = try await provider.stream(model: model, context: context, options: .init(apiKey: token, reasoningEffort: .minimal))
    }

    do {
      let fetch = MockFetchClient(handler: { request in
        let body = try #require(try await bodyData(request))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "high")
        return sseResponse([])
      })

      let provider = OpenAICodexResponsesProvider(fetch: fetch.client)
      let model = Model(id: "gpt-5.1", provider: .openaiCodex)
      let context = Context(systemPrompt: nil, messages: [.user("Hi")])
      _ = try await provider.stream(model: model, context: context, options: .init(apiKey: token, reasoningEffort: .xhigh))
    }
  }
}

private func makeTestJWT(accountId: String) -> String {
  // header and signature are irrelevant for our parsing.
  let header = base64URL(Data(#"{"alg":"none"}"#.utf8))
  let payload = base64URL(Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"\#(accountId)"}}"#.utf8))
  return "\(header).\(payload).sig"
}

private func base64URL(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}
