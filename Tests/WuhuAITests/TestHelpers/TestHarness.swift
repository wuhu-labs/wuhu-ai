import Dependencies
import Foundation
@testable import WuhuAI
import Testing

// MARK: - withRecording

/// Create a recording context and run the test body.
///
/// Always executes the test body — never skips.
/// - If `RECORDING` matches this test's name: records real API responses,
///   saves fixtures atomically if the body completes without throwing.
/// - Otherwise: replays from recorded fixtures (fails if fixtures are missing).
func withRecording(
  _ name: String,
  body: () async throws -> Void,
) async throws {
  let envMode = RecordingMode.fromEnvironment

  // If recording a specific prefix, only record matching tests;
  // non-matching tests replay from existing fixtures.
  let mode: RecordingMode
  if envMode.matches(name) {
    mode = envMode
  } else {
    mode = .replay
  }

  let ctx = RecordingContext(name: name, mode: mode)
  try await withDependencies {
    $0.fetch = ctx.fetchClient
  } operation: {
    try await body()
  }

  // Atomic flush: only persist recordings if the test body passed.
  if mode.isRecording {
    try await ctx.flushRecordings()
  }
}

// MARK: - Endpoint Factory

/// Create a `ModelEndpoint` for integration testing from env vars.
///
/// In replay mode API keys are never used — the recording fetch client
/// returns fixtures. Use empty-string fallbacks so tests work without env vars.
func makeEndpoint(providerID: String, model: String) -> any ModelEndpoint {
  let apiKey: (String) -> String = { ProcessInfo.processInfo.environment[$0] ?? "" }

  switch providerID {
  case "openai":
    return OpenAIGPTEndpoint(model: model, apiKey: apiKey("OPENAI_API_KEY"))

  case "anthropic":
    return AnthropicEndpoint(model: model, apiKey: apiKey("ANTHROPIC_API_KEY"))

  case "deepseek":
    return DeepSeekChatEndpoint(model: model, apiKey: apiKey("DEEPSEEK_API_KEY"))

  case "deepseek-anthropic":
    return DeepSeekAnthropicEndpoint(model: model, apiKey: apiKey("DEEPSEEK_API_KEY"))

  case "gemini":
    return GeminiEndpoint(model: model, apiKey: apiKey("GEMINI_API_KEY"))

  case "kimi":
    return KimiEndpoint(model: model, apiKey: apiKey("MOONSHOT_API_KEY"))

  default:
    // Unknown provider — return a stub that will fail with a clear error.
    return OpenAIGPTEndpoint(model: model, apiKey: "")
  }
}

/// Create an endpoint from the model matrix.
func makeEndpoint(_ entry: ModelEntry) -> any ModelEndpoint {
  makeEndpoint(providerID: entry.providerID, model: entry.model)
}

// MARK: - Model Entry

/// A single entry in the model matrix for parameterized tests.
struct ModelEntry: Sendable, CustomTestStringConvertible {
  let providerID: String
  let model: String
  let recordingName: String

  var testDescription: String {
    "\(providerID)/\(model)"
  }
}
