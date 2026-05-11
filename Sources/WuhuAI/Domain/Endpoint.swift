import Foundation
import JSONValue

// MARK: - Dialect

public enum Dialect: Hashable, Sendable {
  case chatCompletions
  case responses
  case anthropic
  case gemini
}

// MARK: - ResolvedMedia

public enum ResolvedMedia: Sendable {
  case data(Data, mimeType: String)
  case url(URL, mimeType: String)
}

// MARK: - MediaResolver

public protocol MediaResolver: Sendable {
  func resolve(_ media: MediaContent) async throws -> ResolvedMedia
}

// MARK: - ModelEndpoint

public protocol ModelEndpoint: Sendable {
  /// Opaque identity string for cross-provider replay gating.
  var providerID: String { get }

  /// Wire-level model name.
  var model: String { get }

  /// Wire protocol dialect.
  var dialect: Dialect { get }

  /// Base URL for the API endpoint.
  var baseURL: URL { get }

  /// Mutate the dialect's standard request body with provider-specific fields.
  func modifyBody(_ body: inout [String: JSONValue], options: RequestOptions)

  /// Return additional headers to merge.
  func modifyHeaders(_ options: RequestOptions) -> [String: String]

  /// Whether this endpoint "knows" messages from the given source providerID.
  func isSameProvider(_ sourceProviderID: String) -> Bool

  /// Output normalization. Called on the parsed AssistantMessage after the
  /// stream completes and before returning to the caller.
  func normalizeOutput(_ message: inout AssistantMessage)
}

// MARK: - Default Implementations

extension ModelEndpoint {
  public func isSameProvider(_ sourceProviderID: String) -> Bool {
    sourceProviderID == self.providerID
  }

  public func normalizeOutput(_ message: inout AssistantMessage) {
    // Default: no-op. Override for provider-specific normalization.
  }

  public func modifyBody(_ body: inout [String: JSONValue], options: RequestOptions) {
    // Default: no-op.
  }

  public func modifyHeaders(_ options: RequestOptions) -> [String: String] {
    // Default: no additional headers.
    [:]
  }
}
