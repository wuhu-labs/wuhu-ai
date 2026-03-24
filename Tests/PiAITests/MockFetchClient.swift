import Foundation
import Fetch
import FetchSSE
import HTTPTypes
import WuhuAI

struct MockFetchClient {
  var handler: @Sendable (Request) async throws -> Response

  var client: FetchClient {
    FetchClient(fetch: self.handler)
  }
}

func bodyData(_ request: Request) async throws -> Data? {
  guard let body = request.body else { return nil }

  var bytes: Bytes = []
  for try await chunk in body.stream {
    bytes.append(contentsOf: chunk)
  }

  return Data(bytes)
}

func normalizedHeaders(_ request: Request) -> [String: String] {
  Dictionary(
    uniqueKeysWithValues: request.headers.map { field in
      (field.name.rawName.lowercased(), field.value)
    }
  )
}

func sseResponse(
  _ events: [SSEEvent],
  status: Int = 200
) -> Response {
  var headers = Headers()
  headers[.contentType] = "text/event-stream"

  let payload = events.map(serializeSSEEvent).joined()
  return Response(
    status: Status(code: status),
    headers: headers,
    body: .chunk(Array(payload.utf8))
  )
}

private func serializeSSEEvent(_ event: SSEEvent) -> String {
  var lines: [String] = []

  if event.event != "message" {
    lines.append("event: \(event.event)")
  }
  if let id = event.id {
    lines.append("id: \(id)")
  }
  if let retry = event.retry {
    lines.append("retry: \(retry)")
  }

  let dataLines = event.data.split(separator: "\n", omittingEmptySubsequences: false)
  if dataLines.isEmpty {
    lines.append("data:")
  } else {
    for line in dataLines {
      lines.append("data: \(line)")
    }
  }

  return lines.joined(separator: "\n") + "\n\n"
}
