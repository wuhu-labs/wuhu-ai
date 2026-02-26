import Foundation

public enum PiAIError: Error, Sendable, CustomStringConvertible {
  case missingAPIKey(provider: Provider)
  case invalidURL(String)
  case invalidResponse
  case httpStatus(code: Int, body: String?)
  case decoding(String)
  case unsupported(String)

  public var description: String {
    switch self {
    case let .missingAPIKey(provider):
      return "Missing API key for provider: \(provider.rawValue)"
    case let .invalidURL(url):
      return "Invalid URL: \(url)"
    case .invalidResponse:
      return "Invalid response"
    case let .httpStatus(code, body):
      if let body, !body.isEmpty {
        return "HTTP \(code): \(body)"
      }
      return "HTTP \(code)"
    case let .decoding(message):
      return "Decoding error: \(message)"
    case let .unsupported(message):
      return "Unsupported: \(message)"
    }
  }
}
