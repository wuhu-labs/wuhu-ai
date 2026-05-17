@testable import WuhuAI

// MARK: - Inference Helper

/// Send a single inference request through the recording fetch client dependency
/// and return the final assistant message with metadata.
func infer(
  endpoint: any ModelEndpoint,
  context: Context,
  options: RequestOptions = RequestOptions(),
  recording _: RecordingContext,
) async throws -> (AssistantMessage, AssistantMessageMetadata) {
  let inference = try await endpoint.infer(
    context: context,
    options: options,
  )
  return (inference.message, inference.metadata)
}
