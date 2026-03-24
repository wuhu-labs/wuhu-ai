import Foundation
import Fetch
import HTTPTypes

func resolveAPIKey(_ explicit: String?, env: String, provider: Provider) throws -> String {
  if let explicit, !explicit.isEmpty { return explicit }
  if let value = ProcessInfo.processInfo.environment[env], !value.isEmpty { return value }
  throw WuhuAIError.missingAPIKey(provider: provider)
}

func envBool(_ key: String) -> Bool? {
  guard let raw = ProcessInfo.processInfo.environment[key], !raw.isEmpty else { return nil }
  switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
  case "1", "true", "t", "yes", "y", "on":
    return true
  case "0", "false", "f", "no", "n", "off":
    return false
  default:
    return nil
  }
}

func parseJSON(_ text: String) throws -> [String: Any]? {
  let data = Data(text.utf8)
  let obj = try JSONSerialization.jsonObject(with: data)
  return obj as? [String: Any]
}

func applyTextDelta(_ delta: String, to message: inout AssistantMessage) {
  if let last = message.content.last, case var .text(part) = last {
    part.text += delta
    message.content[message.content.count - 1] = .text(part)
  } else {
    message.content.append(.text(.init(text: delta)))
  }
}

func makeJSONRequest(
  url: URL,
  method: Fetch.Method = .post,
  headers: Headers,
  bodyJSONObject: Any
) throws -> Request {
  let body = try JSONSerialization.data(
    withJSONObject: bodyJSONObject,
    options: .sortedKeys
  )

  return Request(
    url: url,
    method: method,
    headers: headers,
    body: .bytes(Array(body), contentType: "application/json")
  )
}

func setHeader(_ value: String, for name: String, in headers: inout Headers) {
  guard let fieldName = HTTPField.Name(name) else { return }
  headers[fieldName] = value
}

func getHeaderValue(_ headers: Headers, name: String) -> String? {
  guard let fieldName = HTTPField.Name(name) else { return nil }
  return headers[fieldName]
}

func validatedResponse(
  for request: Request,
  using fetch: FetchClient
) async throws -> Response {
  let response = try await fetch(request)

  guard (200..<300).contains(response.status.code) else {
    let body = try? await response.text(upTo: 64 * 1024)
    throw WuhuAIError.httpStatus(code: response.status.code, body: body)
  }

  return response
}
