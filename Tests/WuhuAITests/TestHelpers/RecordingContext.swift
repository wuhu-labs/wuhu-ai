#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif
import Fetch
import FetchURLSession
import Foundation
import HTTPTypes

// MARK: - HMAC Sanitization

private let hmacSecret = SymmetricKey(data: Data("jiuziai-recording-hmac-secret-v1".utf8))

private let sensitiveHeaderNames: Set<String> = [
  "authorization",
  "x-api-key",
  "x-goog-api-key",
  "chatgpt-account-id",
]

func sanitizeHeaderValue(headerName: String, value: String) -> String {
  let lowercased = headerName.lowercased()
  guard sensitiveHeaderNames.contains(lowercased) else { return value }
  let message = "\(lowercased):\(value)"
  let signature = HMAC<SHA256>.authenticationCode(
    for: Data(message.utf8),
    using: hmacSecret,
  )
  let hex = signature.map { String(format: "%02x", $0) }.joined()
  return "HMAC:SHA256:\(hex)"
}

// MARK: - Recording Directory

func recordingDirectory(for name: String) -> URL? {
  let sourceFile = URL(fileURLWithPath: #filePath)
  let testsDir = sourceFile.deletingLastPathComponent().deletingLastPathComponent()
  return testsDir
    .appendingPathComponent("IntegrationTests")
    .appendingPathComponent("Recordings")
    .appendingPathComponent(name)
}

// MARK: - Request Counter

private actor RequestCounter {
  private var value = 0

  func next() -> Int {
    value += 1
    return value
  }
}

// MARK: - Recording Collector

private actor RecordingCollector {
  private var pairs: [(sanitizedRequest: Data, responseBytes: Data)] = []

  func append(sanitizedRequest: Data, responseBytes: Data) {
    pairs.append((sanitizedRequest, responseBytes))
  }

  func flush(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
      try? FileManager.default.removeItem(at: file)
    }
    for (index, pair) in pairs.enumerated() {
      let reqFile = directory.appendingPathComponent("\(index + 1).request.json")
      let sseFile = directory.appendingPathComponent("\(index + 1).output.sse")
      try pair.sanitizedRequest.write(to: reqFile)
      try pair.responseBytes.write(to: sseFile)
    }
  }
}

// MARK: - Recording Context

struct RecordingContext: Sendable {
  let name: String
  let fetchClient: FetchClient
  private let collector: RecordingCollector?

  init(name: String, mode: RecordingMode) {
    self.name = name
    let recordDir = recordingDirectory(for: name)!
    let counter = RequestCounter()

    switch mode {
    case .recordAll, .recordOnly:
      let collector = RecordingCollector()
      self.collector = collector
      let realClient = FetchClient.urlSession()

      self.fetchClient = FetchClient { request in
        let _ = await counter.next()
        return try await recordRequest(
          request: request,
          recordDir: recordDir,
          realClient: realClient,
          collector: collector,
        )
      }

    case .replay:
      self.collector = nil
      self.fetchClient = FetchClient { request in
        let idx = await counter.next()
        return try await replayResponse(
          request: request, index: idx,
          recordDir: recordDir,
        )
      }
    }
  }

  func flushRecordings() async throws {
    guard let collector else { return }
    let dir = recordingDirectory(for: name)!
    try await collector.flush(to: dir)
  }
}

// MARK: - Record

private func recordRequest(
  request: Request,
  recordDir _: URL,
  realClient: FetchClient,
  collector: RecordingCollector,
) async throws -> Response {
  // Collect the request body once — it can only be consumed once.
  let requestBodyData: Data
  if let body = request.body {
    requestBodyData = try await body.data()
  } else {
    requestBodyData = Data()
  }

  // Serialize the sanitized request for recording.
  let sanitizedHeaders = sanitizeHeaders(request.headers)
  let reqData = serializeRequestForRecording(
    url: request.url,
    method: request.method,
    headers: sanitizedHeaders,
    bodyData: requestBodyData,
  )

  // Build a fresh request with a new body for the real client.
  let freshRequest = Request(
    url: request.url,
    method: request.method,
    headers: request.headers,
    body: requestBodyData.isEmpty
      ? nil
      : .bytes(Array(requestBodyData), contentType: request.body?.contentType),
  )

  // Make the real request.
  let response = try await realClient.fetch(freshRequest)
  guard (200 ..< 300).contains(response.status.code) else {
    let bodyText = (try? await response.body.text(upTo: 4096)) ?? "<no body>"
    throw IntegrationTestError.unexpectedStatus(response.status.code, bodyText)
  }
  let bodyBytes = try await response.body.bytes()

  let responseData = Data(bodyBytes)
  await collector.append(sanitizedRequest: reqData, responseBytes: responseData)

  return Response(
    status: response.status,
    headers: response.headers,
    body: .bytes(bodyBytes, contentType: response.body.contentType),
  )
}

// MARK: - Replay

func replayResponse(
  request: Request,
  index: Int,
  recordDir: URL,
) async throws -> Response {
  let reqFile = recordDir.appendingPathComponent("\(index).request.json")
  let sseFile = recordDir.appendingPathComponent("\(index).output.sse")

  guard FileManager.default.fileExists(atPath: reqFile.path) else {
    throw IntegrationTestError.noRecordingsFound(recordDir.lastPathComponent)
  }

  // Collect the current request body.
  let currentBodyData: Data
  if let body = request.body {
    currentBodyData = try await body.data()
  } else {
    currentBodyData = Data()
  }

  // Serialize current body with sorted keys for comparison.
  let currentBodyJSON: Any
  if !currentBodyData.isEmpty,
     let json = try? JSONSerialization.jsonObject(with: currentBodyData)
  {
    currentBodyJSON = json
  } else {
    currentBodyJSON = NSNull()
  }

  // Load recorded fixture.
  let recordedData = try Data(contentsOf: reqFile)
  let recordedJSON = try JSONSerialization.jsonObject(with: recordedData)
  guard var recordedDict = recordedJSON as? [String: Any],
        let _ = recordedDict["body"]
  else {
    throw IntegrationTestError.noRecordingsFound(recordDir.lastPathComponent)
  }

  // Strip sensitive headers from the recorded fixture before comparison.
  if var recordedHeaders = recordedDict["headers"] as? [String: String] {
    recordedHeaders = recordedHeaders.filter { !sensitiveHeaderNames.contains($0.key.lowercased()) }
    recordedDict["headers"] = recordedHeaders
  }

  // Build the current request dict with sanitized headers.
  let currentHeaders = sanitizeHeaders(request.headers)
    .filter { !sensitiveHeaderNames.contains($0.key.lowercased()) }
  let currentDict: [String: Any] = [
    "url": request.url.absoluteString,
    "method": request.method.rawValue,
    "headers": currentHeaders,
    "body": currentBodyJSON,
  ]

  // Serialize both with sorted keys for stable comparison.
  let recordedSerialized = try JSONSerialization.data(
    withJSONObject: recordedDict, options: [.sortedKeys, .prettyPrinted],
  )
  let currentSerialized = try JSONSerialization.data(
    withJSONObject: currentDict, options: [.sortedKeys, .prettyPrinted],
  )

  guard recordedSerialized == currentSerialized else {
    let recorded = String(data: recordedSerialized, encoding: .utf8) ?? "<binary>"
    let current = String(data: currentSerialized, encoding: .utf8) ?? "<binary>"
    throw IntegrationTestError.requestBodyMismatch(expected: recorded, actual: current)
  }

  guard FileManager.default.fileExists(atPath: sseFile.path) else {
    throw IntegrationTestError.noRecordingsFound(recordDir.lastPathComponent)
  }

  let sseBytes = try Data(contentsOf: sseFile)
  return Response(
    status: .ok,
    headers: HTTPFields(),
    body: .bytes(Array(sseBytes), contentType: "text/event-stream"),
  )
}

// MARK: - Header Sanitization

private func sanitizeHeaders(_ headers: HTTPFields) -> [String: String] {
  var dict: [String: String] = [:]
  for field in headers {
    let sanitizedValue = sanitizeHeaderValue(
      headerName: field.name.rawName,
      value: field.value,
    )
    dict[field.name.rawName] = sanitizedValue
  }
  return dict
}

// MARK: - Serialization

private func serializeRequestForRecording(
  url: URL,
  method: HTTPRequest.Method,
  headers: [String: String],
  bodyData: Data,
) -> Data {
  var dict: [String: Any] = [
    "url": url.absoluteString,
    "method": method.rawValue,
    "headers": headers,
  ]
  if !bodyData.isEmpty {
    if let json = try? JSONSerialization.jsonObject(with: bodyData) {
      dict["body"] = json
    } else {
      dict["body"] = "non-JSON body of \(bodyData.count) bytes"
    }
  }
  return try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .prettyPrinted])
}
