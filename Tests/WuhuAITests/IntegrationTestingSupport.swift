import Fetch
import Foundation
import HTTPTypes
import Testing

#if os(macOS) && canImport(FetchURLSession)
import FetchURLSession
#endif

private let sidecarBaseURL = URL(string: "http://127.0.0.1:11451")!
private let sidecarRealHostHeader = "x-wuhu-ai-real-host"
private let recordingModeEnvironmentKey = "WUHU_AI_RECORD_INTEGRATION_TESTS"
private let recordingFileExtension = "llm-recording.json"

struct IntegrationTestRecordingContext {
  let testName: String
  let sourceFilePath: String
  private let mode: RecordingMode

  private let state = RecordingState()
  private let liveFetch: FetchClient?

  init(testName: String, sourceFilePath: StaticString = #filePath) throws {
    self.testName = testName
    self.sourceFilePath = "\(sourceFilePath)"
    self.mode = .current

    switch self.mode {
    case .replay:
      self.liveFetch = nil

    case .recordMissing:
      #if os(macOS) && canImport(FetchURLSession)
      self.liveFetch = .urlSession(URLSession(configuration: .ephemeral))
      #else
      throw RecordingError.recordingModeUnsupported
      #endif
    }
  }

  var fetchClient: FetchClient {
    FetchClient { request in
      let requestID = await self.state.nextRequestID()
      let recordingURL = try self.recordingURL(for: requestID)
      let recordedRequest = try await self.makeRecordedRequest(from: request)

      if FileManager.default.fileExists(atPath: recordingURL.path) {
        let recording = try self.loadRecording(at: recordingURL)
        guard recording.request == recordedRequest else {
          throw RecordingError.requestMismatch(
            path: recordingURL.path,
            expected: recording.request,
            actual: recordedRequest,
          )
        }
        return try recording.response.makeResponse()
      }

      switch self.mode {
      case .replay:
        throw RecordingError.missingRecording(path: recordingURL.path)

      case .recordMissing:
        guard let liveFetch = self.liveFetch else {
          throw RecordingError.recordingModeUnsupported
        }

        let forwardedRequest = try self.makeForwardedRequest(from: recordedRequest)
        let liveResponse = try await liveFetch(forwardedRequest)
        let recordedResponse = try await RecordedResponse(response: liveResponse)
        let recording = LLMRecording(request: recordedRequest, response: recordedResponse)
        try self.saveRecording(recording, to: recordingURL)
        return try recordedResponse.makeResponse()
      }
    }
  }

  private func recordingURL(for requestID: String) throws -> URL {
    let sourceURL = URL(fileURLWithPath: self.sourceFilePath)
    let recordingsDirectory = sourceURL
      .deletingLastPathComponent()
      .appendingPathComponent("Recordings", isDirectory: true)

    try FileManager.default.createDirectory(
      at: recordingsDirectory,
      withIntermediateDirectories: true,
      attributes: nil,
    )

    let fileName = sourceURL.deletingPathExtension().lastPathComponent
    return recordingsDirectory.appendingPathComponent(
      "\(fileName).\(self.testName).\(requestID).\(recordingFileExtension)",
      isDirectory: false,
    )
  }

  private func makeRecordedRequest(from request: Request) async throws -> RecordedRequest {
    let body = try await RecordedBody.capture(request.body)
    return RecordedRequest(
      url: request.url.absoluteString,
      method: request.method.rawValue,
      headers: RecordedHeader.captureAndSanitize(request.headers),
      body: body,
    )
  }

  private func makeForwardedRequest(from request: RecordedRequest) throws -> Request {
    guard let originalURL = URL(string: request.url),
          let realHost = originalURL.host
    else {
      throw RecordingError.invalidRequestURL(request.url)
    }

    guard var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else {
      throw RecordingError.invalidRequestURL(request.url)
    }
    components.scheme = sidecarBaseURL.scheme
    components.host = sidecarBaseURL.host
    components.port = sidecarBaseURL.port

    guard let forwardedURL = components.url else {
      throw RecordingError.invalidRequestURL(request.url)
    }

    guard let method = Method(rawValue: request.method) else {
      throw RecordingError.invalidRequestMethod(request.method)
    }

    var headers = request.headers.makeHeaders()
    RecordedHeader.set(sidecarRealHostHeader, to: realHost, in: &headers)

    return Request(
      url: forwardedURL,
      method: method,
      headers: headers,
      body: request.body?.makeBody(),
    )
  }

  private func loadRecording(at url: URL) throws -> LLMRecording {
    let data = try Data(contentsOf: url)
    return try JSONDecoder.recording.decode(LLMRecording.self, from: data)
  }

  private func saveRecording(_ recording: LLMRecording, to url: URL) throws {
    let data = try JSONEncoder.recording.encode(recording)
    try data.write(to: url, options: .atomic)
  }
}

private actor RecordingState {
  private var requestCount = 0

  func nextRequestID() -> String {
    self.requestCount += 1
    return String(format: "%03d", self.requestCount)
  }
}

private enum RecordingMode {
  case replay
  case recordMissing

  static var current: Self {
    let value = ProcessInfo.processInfo.environment[recordingModeEnvironmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    return switch value {
    case "1", "true", "yes", "record":
      .recordMissing
    default:
      .replay
    }
  }
}

private struct LLMRecording: Codable, Equatable, Sendable {
  var request: RecordedRequest
  var response: RecordedResponse
}

private struct RecordedRequest: Codable, Equatable, Sendable {
  var url: String
  var method: String
  var headers: [RecordedHeader]
  var body: RecordedBody?
}

private struct RecordedResponse: Codable, Equatable, Sendable {
  var statusCode: Int
  var headers: [RecordedHeader]
  var body: RecordedBody

  init(response: Response) async throws {
    self.statusCode = response.status.code
    self.headers = RecordedHeader.capture(response.headers)
    self.body = try await RecordedBody.capture(response.body) ?? .utf8("")
  }

  func makeResponse() throws -> Response {
    let headers = self.headers.makeHeaders()
    let contentType = self.headers.firstValue(named: "Content-Type")
    return Response(
      status: Status(code: self.statusCode),
      headers: headers,
      body: self.body.makeBody(contentType: contentType),
    )
  }
}

private struct RecordedHeader: Codable, Equatable, Sendable {
  var name: String
  var value: String

  static func capture(_ headers: Headers) -> [Self] {
    headers.map { header in
      Self(name: header.name.rawName, value: header.value)
    }
    .sorted {
      ($0.name.lowercased(), $0.value) < ($1.name.lowercased(), $1.value)
    }
  }

  static func captureAndSanitize(_ headers: Headers) -> [Self] {
    capture(headers).map { header in
      let name = header.name.lowercased()
      return switch name {
      case "authorization":
        Self(name: header.name, value: "Bearer redacted")
      case "x-api-key", "chatgpt-account-id":
        Self(name: header.name, value: "redacted")
      default:
        header
      }
    }
  }

  static func set(_ name: String, to value: String, in headers: inout Headers) {
    if let fieldName = HTTPField.Name(name) {
      headers[fieldName] = value
    }
  }
}

private enum RecordedBody: Equatable, Sendable {
  case utf8(String)
  case base64(String)

  static func capture(_ body: Body?) async throws -> Self? {
    guard let body else { return nil }
    let bytes = try await body.bytes()
    if let string = String(bytes: bytes, encoding: .utf8) {
      return .utf8(string)
    } else {
      return .base64(Data(bytes).base64EncodedString())
    }
  }

  func makeBody(contentType: String? = nil) -> Body {
    switch self {
    case let .utf8(string):
      return .bytes(Array(string.utf8), contentType: contentType)
    case let .base64(string):
      let data = Data(base64Encoded: string) ?? Data()
      return .bytes(Array(data), contentType: contentType)
    }
  }
}

extension RecordedBody: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case text
  }

  private enum Kind: String, Codable {
    case utf8
    case base64
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .utf8:
      self = .utf8(try container.decode(String.self, forKey: .text))
    case .base64:
      self = .base64(try container.decode(String.self, forKey: .text))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .utf8(text):
      try container.encode(Kind.utf8, forKey: .kind)
      try container.encode(text, forKey: .text)
    case let .base64(text):
      try container.encode(Kind.base64, forKey: .kind)
      try container.encode(text, forKey: .text)
    }
  }
}

private enum RecordingError: Error, CustomStringConvertible {
  case missingRecording(path: String)
  case requestMismatch(path: String, expected: RecordedRequest, actual: RecordedRequest)
  case invalidRequestURL(String)
  case invalidRequestMethod(String)
  case recordingModeUnsupported

  var description: String {
    switch self {
    case let .missingRecording(path):
      return "Missing integration recording at \(path). Delete only the request you want to re-record, then set \(recordingModeEnvironmentKey)=1 while the sidecar proxy is running."

    case let .requestMismatch(path, expected, actual):
      return "Recorded request mismatch for \(path).\n\nExpected:\n\(expected.prettyPrintedJSON)\n\nActual:\n\(actual.prettyPrintedJSON)"

    case let .invalidRequestURL(url):
      return "Invalid request URL for integration test recording: \(url)"

    case let .invalidRequestMethod(method):
      return "Invalid HTTP method for integration test recording: \(method)"

    case .recordingModeUnsupported:
      return "Recording mode requires FetchURLSession and is intentionally limited to local macOS recording."
    }
  }
}

private extension Array where Element == RecordedHeader {
  func makeHeaders() -> Headers {
    var headers = Headers()
    for header in self {
      if let name = HTTPField.Name(header.name) {
        headers[name] = header.value
      }
    }
    return headers
  }

  func firstValue(named name: String) -> String? {
    self.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
  }
}

private extension JSONEncoder {
  static var recording: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

private extension JSONDecoder {
  static var recording: JSONDecoder {
    JSONDecoder()
  }
}

private extension Encodable {
  var prettyPrintedJSON: String {
    guard let data = try? JSONEncoder.recording.encode(AnyEncodable(self)),
          let string = String(data: data, encoding: .utf8)
    else {
      return String(describing: self)
    }
    return string
  }
}

private struct AnyEncodable: Encodable {
  private let encodeOperation: (Encoder) throws -> Void

  init(_ base: some Encodable) {
    self.encodeOperation = base.encode(to:)
  }

  func encode(to encoder: Encoder) throws {
    try self.encodeOperation(encoder)
  }
}
