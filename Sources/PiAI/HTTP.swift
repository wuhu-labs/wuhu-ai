import Foundation

// MARK: - Request / Response

public struct HTTPRequest: Sendable {
  public var url: URL
  public var method: String
  public var headers: [String: [String]]
  public var body: Data?

  public init(
    url: URL,
    method: String = "GET",
    headers: [String: [String]] = [:],
    body: Data? = nil
  ) {
    self.url = url
    self.method = method
    self.headers = headers
    self.body = body
  }

  public mutating func setHeader(_ value: String, for name: String) {
    headers[name] = [value]
  }

  public mutating func addHeader(_ value: String, for name: String) {
    headers[name, default: []].append(value)
  }
}

public struct HTTPResponse: Sendable {
  public var statusCode: Int
  public var headers: [String: [String]]

  public init(statusCode: Int, headers: [String: [String]] = [:]) {
    self.statusCode = statusCode
    self.headers = headers
  }
}

// MARK: - SSE

public struct SSEMessage: Sendable, Hashable {
  public var event: String?
  public var data: String

  public init(event: String? = nil, data: String) {
    self.event = event
    self.data = data
  }
}

public struct SSEResponse: Sendable {
  public var response: HTTPResponse
  public var events: AsyncThrowingStream<SSEMessage, any Error>

  public init(response: HTTPResponse, events: AsyncThrowingStream<SSEMessage, any Error>) {
    self.response = response
    self.events = events
  }
}

// MARK: - Client Protocol

public protocol HTTPClient: Sendable {
  func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse)
  func sse(for request: HTTPRequest) async throws -> SSEResponse
}

// MARK: - SSE Decoder

public enum SSEDecoder {
  public static func decode(_ data: Data) -> AsyncThrowingStream<SSEMessage, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        var buffer = data
        drain(buffer: &buffer, continuation: continuation)
        continuation.finish()
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  public static func drain(
    buffer: inout Data,
    continuation: AsyncThrowingStream<SSEMessage, any Error>.Continuation
  ) {
    while true {
      if let range = buffer.range(of: Data([13, 10, 13, 10])) { // \r\n\r\n
        let chunkData = buffer.subdata(in: 0 ..< range.lowerBound)
        buffer.removeSubrange(0 ..< range.upperBound)
        yieldChunk(chunkData, continuation: continuation)
        continue
      }
      if let range = buffer.range(of: Data([10, 10])) { // \n\n
        let chunkData = buffer.subdata(in: 0 ..< range.lowerBound)
        buffer.removeSubrange(0 ..< range.upperBound)
        yieldChunk(chunkData, continuation: continuation)
        continue
      }
      break
    }
  }

  public static func parseChunk(_ chunk: String) -> SSEMessage? {
    var event: String?
    var dataLines: [String] = []

    for rawLine in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("event:") {
        event = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
      } else if line.hasPrefix("data:") {
        let data = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        dataLines.append(data)
      }
    }

    let data = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !data.isEmpty, data != "[DONE]" else { return nil }
    return SSEMessage(event: event, data: data)
  }

  private static func yieldChunk(
    _ chunkData: Data,
    continuation: AsyncThrowingStream<SSEMessage, any Error>.Continuation
  ) {
    if chunkData.isEmpty { return }
    var chunk = String(decoding: chunkData, as: UTF8.self)
    chunk = chunk.replacingOccurrences(of: "\r\n", with: "\n")
    if let message = parseChunk(chunk) {
      continuation.yield(message)
    }
  }
}
