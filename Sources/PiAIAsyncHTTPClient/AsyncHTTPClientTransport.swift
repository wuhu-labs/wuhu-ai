import AsyncHTTPClient
import Foundation
import PiAI

public final class AsyncHTTPClientTransport: PiAI.HTTPClient, @unchecked Sendable {
  private let client: AsyncHTTPClient.HTTPClient
  private let requestTimeoutSeconds: Int64
  private let sseTimeoutSeconds: Int64
  private let ownsClient: Bool

  public convenience init(
    client: AsyncHTTPClient.HTTPClient? = nil,
    requestTimeoutSeconds: Int64 = 300
  ) {
    self.init(
      client: client,
      requestTimeoutSeconds: requestTimeoutSeconds,
      sseTimeoutSeconds: 86400,
    )
  }

  public init(
    client: AsyncHTTPClient.HTTPClient? = nil,
    requestTimeoutSeconds: Int64 = 300,
    sseTimeoutSeconds: Int64
  ) {
    if let client {
      self.client = client
      ownsClient = false
    } else {
      var config = AsyncHTTPClient.HTTPClient.Configuration()
      config.decompression = .enabled(limit: .none)
      self.client = AsyncHTTPClient.HTTPClient(
        eventLoopGroupProvider: .singleton,
        configuration: config,
      )
      ownsClient = true
    }
    self.requestTimeoutSeconds = requestTimeoutSeconds
    self.sseTimeoutSeconds = sseTimeoutSeconds
  }

  deinit {
    guard ownsClient else { return }
    try? client.syncShutdown()
  }

  public func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
    let response = try await execute(request, timeoutSeconds: requestTimeoutSeconds)
    let body = try await readBody(response.body, limitBytes: .max)
    return (body, makeResponseMetadata(response))
  }

  public func sse(for request: HTTPRequest) async throws -> SSEResponse {
    let response = try await execute(request, timeoutSeconds: sseTimeoutSeconds)
    let metadata = makeResponseMetadata(response)

    if metadata.statusCode < 200 || metadata.statusCode >= 300 {
      let body = try await readBody(response.body, limitBytes: 64 * 1024)
      throw PiAIError.httpStatus(
        code: metadata.statusCode,
        body: String(decoding: body, as: UTF8.self),
      )
    }

    // Keep `self` alive for the lifetime of the stream. Callers often create
    // a temporary transport/client and only retain the returned stream. If the
    // transport is deinitialized, it will shut down the underlying
    // AsyncHTTPClient and cancel the in-flight SSE body stream.
    let body = response.body
    let events = AsyncThrowingStream<SSEMessage, any Error> { continuation in
      let task = Task { [self] in
        _ = self
        do {
          var buffer = Data()
          buffer.reserveCapacity(8 * 1024)

          for try await var chunk in body {
            guard let bytes = chunk.readBytes(length: chunk.readableBytes),
                  !bytes.isEmpty
            else { continue }
            buffer.append(contentsOf: bytes)
            SSEDecoder.drain(buffer: &buffer, continuation: continuation)
          }

          continuation.finish()
        } catch {
          if Task.isCancelled {
            continuation.finish()
          } else {
            continuation.finish(throwing: error)
          }
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }

    return SSEResponse(response: metadata, events: events)
  }

  private func execute(
    _ request: HTTPRequest,
    timeoutSeconds: Int64
  ) async throws -> AsyncHTTPClient.HTTPClientResponse {
    var outgoing = AsyncHTTPClient.HTTPClientRequest(url: request.url.absoluteString)
    outgoing.method = .RAW(value: request.method.uppercased())

    for (name, values) in request.headers {
      for value in values {
        outgoing.headers.add(name: name, value: value)
      }
    }

    if let body = request.body {
      outgoing.body = .bytes(body)
    }

    return try await client.execute(outgoing, timeout: .seconds(timeoutSeconds))
  }

  private func makeResponseMetadata(
    _ response: AsyncHTTPClient.HTTPClientResponse
  ) -> HTTPResponse {
    var headers: [String: [String]] = [:]
    for header in response.headers {
      headers[header.name, default: []].append(header.value)
    }
    return HTTPResponse(statusCode: Int(response.status.code), headers: headers)
  }

  private func readBody(
    _ body: AsyncHTTPClient.HTTPClientResponse.Body,
    limitBytes: Int
  ) async throws -> Data {
    var data = Data()
    data.reserveCapacity(min(4 * 1024, limitBytes))
    var count = 0

    for try await var chunk in body {
      let readable = chunk.readableBytes
      if readable == 0 { continue }

      let remaining = limitBytes - count
      if remaining <= 0 { break }

      let toRead = min(readable, remaining)
      guard let bytes = chunk.readBytes(length: toRead) else { continue }
      data.append(contentsOf: bytes)
      count += bytes.count

      if toRead < readable {
        break
      }
    }

    return data
  }
}
