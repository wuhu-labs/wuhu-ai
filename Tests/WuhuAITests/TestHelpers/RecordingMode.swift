import Foundation

// MARK: - Recording Mode

/// Controls whether integration tests record or replay.
enum RecordingMode: Sendable {
  /// Make real HTTP requests and save fixtures.
  case recordAll

  /// Record only tests whose recording name starts with the given prefix.
  /// Non-matching tests replay from existing fixtures.
  case recordOnly(prefix: String)

  /// Replay from recorded fixtures. No network.
  case replay

  /// Whether this mode makes real HTTP requests.
  var isRecording: Bool {
    switch self {
    case .recordAll, .recordOnly:
      return true
    case .replay:
      return false
    }
  }

  /// The recording mode from the environment.
  /// - `.replay` if `RECORDING` is unset.
  /// - `.recordAll` if `RECORDING=1`.
  /// - `.recordOnly(prefix:)` for any other value.
  static var fromEnvironment: Self {
    guard let env = ProcessInfo.processInfo.environment["RECORDING"], !env.isEmpty else {
      return .replay
    }
    if env == "1" {
      return .recordAll
    }
    return .recordOnly(prefix: env)
  }

  /// Whether this mode should record a test with the given recording name.
  func matches(_ name: String) -> Bool {
    switch self {
    case .recordAll:
      return true
    case let .recordOnly(prefix):
      return name.hasPrefix(prefix)
    case .replay:
      return false
    }
  }
}

// MARK: - Integration Test Error

enum IntegrationTestError: Error, CustomStringConvertible {
  case missingAPIKey(String)
  case noRecordingsFound(String)
  case requestBodyMismatch(expected: String, actual: String)
  case unexpectedStatus(Int, String)

  var description: String {
    switch self {
    case let .missingAPIKey(name):
      return "Missing API key environment variable: \(name)"
    case let .noRecordingsFound(name):
      return """
      No recordings found for "\(name)".
      Run with RECORDING=1 to create them: RECORDING=1 swift test --package-path Packages/Jiuzi
      """
    case let .requestBodyMismatch(expected, actual):
      return "Request body mismatch.\nExpected: \(expected)\nActual: \(actual)"
    case let .unexpectedStatus(code, body):
      return "Unexpected HTTP status \(code). Body: \(body.prefix(500))"
    }
  }
}

// MARK: - API Key Helper

/// Read a required API key from the environment.
func requireAPIKey(_ name: String) throws -> String {
  guard let key = ProcessInfo.processInfo.environment[name], !key.isEmpty else {
    throw IntegrationTestError.missingAPIKey(name)
  }
  return key
}
