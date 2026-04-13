import Foundation
import Testing
import WuhuAI

struct OpenAICodexResponsesIntegrationTests {
  @Test func gpt51CodexEmitsToolCall() async throws {
    let recordingContext = try IntegrationTestRecordingContext(testName: #function, sourceFilePath: #filePath)
    let provider = OpenAICodexResponsesProvider(fetch: recordingContext.fetchClient)

    let context = Context(
      systemPrompt: "You must call the lookup_weather tool before answering the user.",
      messages: [
        .user("What is the weather in Tokyo right now?"),
      ],
      tools: [
        .init(
          name: "lookup_weather",
          description: "Look up the weather for a city.",
          parameters: .object([
            "type": .string("object"),
            "properties": .object([
              "city": .object([
                "type": .string("string"),
              ]),
            ]),
            "required": .array([.string("city")]),
          ])
        ),
      ]
    )

    let message = try await finalMessage(
      from: provider,
      model: Model(id: "gpt-5.1-codex", provider: .openaiCodex),
      context: context,
      options: .init(
        apiKey: try codexIntegrationToken(),
      ),
    )

    let toolCall = try #require(message.content.compactMap(toolCall).first)
    #expect(toolCall.name == "lookup_weather")
    #expect(toolCall.arguments.object?["city"] == JSONValue.string("Tokyo"))
    #expect(message.stopReason == StopReason.toolUse)
  }
}

private func finalMessage(
  from provider: OpenAICodexResponsesProvider,
  model: Model,
  context: Context,
  options: RequestOptions,
) async throws -> AssistantMessage {
  let stream = try await provider.stream(model: model, context: context, options: options)
  var done: AssistantMessage?
  for try await event in stream {
    if case let .done(message) = event {
      done = message
    }
  }
  return try #require(done)
}

private func toolCall(_ block: ContentBlock) -> ToolCall? {
  if case let .toolCall(call) = block { return call }
  return nil
}

private func codexIntegrationToken() throws -> String {
  if !isRecordingIntegrationTests() {
    return makeReplaySafeJWT(accountId: "redacted")
  }

  for environmentKey in ["WUHU_AI_OPENAI_CODEX_TOKEN", "WUHU_AI_OPENAI_CODEX_ID_TOKEN"] {
    if let token = ProcessInfo.processInfo.environment[environmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty
    {
      return token
    }
  }

  let authURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex", isDirectory: true)
    .appendingPathComponent("auth.json", isDirectory: false)

  let data = try Data(contentsOf: authURL)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  let tokens = json?["tokens"] as? [String: Any]

  for key in ["access_token", "id_token"] {
    if let token = tokens?[key] as? String,
       !token.isEmpty,
       !isExpiredJWT(token)
    {
      return token
    }
  }

  if let token = tokens?["id_token"] as? String, !token.isEmpty {
    return token
  }
  if let token = tokens?["access_token"] as? String, !token.isEmpty {
    return token
  }

  throw CodexIntegrationTestError.missingAuthToken(authURL.path)
}

private func isExpiredJWT(_ token: String, leeway: TimeInterval = 60) -> Bool {
  let parts = token.split(separator: ".")
  guard parts.count == 3,
        let payloadData = base64URLDecode(String(parts[1])),
        let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
        let exp = payload["exp"] as? Double
  else {
    return false
  }

  return Date(timeIntervalSince1970: exp) <= Date().addingTimeInterval(leeway)
}

private func isRecordingIntegrationTests() -> Bool {
  let value = ProcessInfo.processInfo.environment["WUHU_AI_RECORD_INTEGRATION_TESTS"]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .lowercased()
  return switch value {
  case "1", "true", "yes", "record":
    true
  default:
    false
  }
}

private func makeReplaySafeJWT(accountId: String) -> String {
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

private func base64URLDecode(_ base64url: String) -> Data? {
  var base64 = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  let padding = 4 - (base64.count % 4)
  if padding < 4 {
    base64 += String(repeating: "=", count: padding)
  }
  return Data(base64Encoded: base64)
}

private enum CodexIntegrationTestError: Error, CustomStringConvertible {
  case missingAuthToken(String)

  var description: String {
    switch self {
    case let .missingAuthToken(path):
      return "Missing tokens.access_token/id_token in \(path). Set WUHU_AI_OPENAI_CODEX_TOKEN or populate ~/.codex/auth.json before recording."
    }
  }
}
