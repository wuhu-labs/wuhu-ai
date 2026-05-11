import Foundation
@testable import WuhuAI
import Testing

// MARK: - Cross-Provider Handoff

/// Test feeding a conversation from one provider to another.

private let systemPrompt = "You are a helpful assistant. Answer concisely."

// MARK: - Same Dialect Handoff

private let sameDialectPairs: [(String, String, String, String)] = [
  // (sourceProvider, sourceModel, targetProvider, targetModel)
  ("anthropic", "claude-sonnet-4-6", "anthropic", "claude-opus-4-7"),
]

@Suite struct SameDialectHandoffTests {
  @Test(arguments: sameDialectPairs)
  func crossProviderSameDialect(
    sourceProvider: String, sourceModel: String,
    targetProvider: String, targetModel: String,
  ) async throws {
    let recordingName = "\(sourceModel)-to-\(targetModel)-handoff"
    try await withRecording(recordingName) { recording in
      let sourceEndpoint = makeEndpoint(providerID: sourceProvider, model: sourceModel)
      let targetEndpoint = makeEndpoint(providerID: targetProvider, model: targetModel)

      // Turn 1: Source generates a response.
      var context = Context(
        systemPrompt: systemPrompt,
        messages: [
          .user(UserMessage(content: [.text(TextContent(text: "What is 2 + 2?"))])),
        ],
      )
      let (sourceMsg, _) = try await infer(
        endpoint: sourceEndpoint,
        context: context,
        options: RequestOptions(),
        recording: recording,
      )
      #expect(!sourceMsg.content.isEmpty)

      // Turn 2: Feed to target.
      context.messages.append(.assistant(sourceMsg))
      context.messages.append(.user(UserMessage(content: [.text(TextContent(text: "Are you sure? Double-check."))])))

      let normalizedContext = transformedContext(
        context,
        from: sourceEndpoint.providerID,
        to: targetEndpoint,
      )
      let (targetMsg, _) = try await infer(
        endpoint: targetEndpoint,
        context: normalizedContext,
        options: RequestOptions(),
        recording: recording,
      )
      #expect(!targetMsg.content.isEmpty)
    }
  }
}

// MARK: - Different Dialect Handoff

private let crossDialectPairs: [(String, String, String, String)] = [
  ("anthropic", "claude-sonnet-4-6", "deepseek", "deepseek-v4-pro"),
  ("deepseek", "deepseek-v4-pro", "anthropic", "claude-sonnet-4-6"),
]

@Suite struct CrossDialectHandoffTests {
  @Test(arguments: crossDialectPairs)
  func crossProviderDifferentDialect(
    sourceProvider: String, sourceModel: String,
    targetProvider: String, targetModel: String,
  ) async throws {
    let recordingName = "\(sourceModel)-to-\(targetModel)-cross-dialect"
    try await withRecording(recordingName) { recording in
      let sourceEndpoint = makeEndpoint(providerID: sourceProvider, model: sourceModel)
      let targetEndpoint = makeEndpoint(providerID: targetProvider, model: targetModel)

      // Turn 1: Source generates.
      var context = Context(
        systemPrompt: systemPrompt,
        messages: [
          .user(UserMessage(content: [.text(TextContent(text: "What is the capital of France?"))])),
        ],
      )
      let (sourceMsg, _) = try await infer(
        endpoint: sourceEndpoint,
        context: context,
        options: RequestOptions(),
        recording: recording,
      )

      // Turn 2: Feed to target.
      context.messages.append(.assistant(sourceMsg))
      context.messages.append(.user(UserMessage(content: [.text(TextContent(text: "What about Germany?"))])))

      let normalizedContext = transformedContext(
        context,
        from: sourceEndpoint.providerID,
        to: targetEndpoint,
      )
      let (targetMsg, _) = try await infer(
        endpoint: targetEndpoint,
        context: normalizedContext,
        options: RequestOptions(),
        recording: recording,
      )
      #expect(!targetMsg.content.isEmpty)
    }
  }
}

// MARK: - With Reasoning Handoff

@Suite struct ReasoningHandoffTests {
  @Test
  func reasoningCrossProviderHandoff() async throws {
    let recordingName = "claude-sonnet-4-6-to-deepseek-v4-pro-reasoning-handoff"
    try await withRecording(recordingName) { recording in
      let sourceEndpoint = makeEndpoint(providerID: "anthropic", model: "claude-sonnet-4-6")
      let targetEndpoint = makeEndpoint(providerID: "deepseek", model: "deepseek-v4-pro")

      // Source generates reasoning with signature.
      var context = Context(
        systemPrompt: "Think step by step before answering.",
        messages: [
          .user(UserMessage(content: [.text(TextContent(text: "If a train travels at 60 mph for 2.5 hours, how far does it go?"))])),
        ],
      )
      let (sourceMsg, _) = try await infer(
        endpoint: sourceEndpoint,
        context: context,
        options: RequestOptions(reasoning: .effort("high")),
        recording: recording,
      )
      #expect(!sourceMsg.content.isEmpty)

      // Verify source has reasoning with signature.
      let sourceReasoning = sourceMsg.content.compactMap { block -> ReasoningContent? in
        if case let .reasoning(r) = block { return r }
        return nil
      }
      #expect(!sourceReasoning.isEmpty, "Source should produce reasoning blocks")
      if let firstReasoning = sourceReasoning.first,
         case let .encrypted(enc) = firstReasoning
      {
        #expect(enc.providerID == "anthropic", "Anthropic reasoning should have providerID 'anthropic'")
      }

      // Handoff to deepseek.
      context.messages.append(.assistant(sourceMsg))
      context.messages.append(.user(UserMessage(content: [.text(TextContent(text: "Convert your answer to kilometers."))])))

      let normalizedContext = transformedContext(
        context,
        from: sourceEndpoint.providerID,
        to: targetEndpoint,
      )
      let (targetMsg, _) = try await infer(
        endpoint: targetEndpoint,
        context: normalizedContext,
        options: RequestOptions(reasoning: .effort("high")),
        recording: recording,
      )
      #expect(!targetMsg.content.isEmpty)

      // Target should receive plain-text reasoning, not signature blocks.
      let targetReasoning = targetMsg.content.compactMap { block -> ReasoningContent? in
        if case let .reasoning(r) = block { return r }
        return nil
      }
      for block in targetReasoning {
        if case .unencrypted = block { } else {
          #expect(Bool(false), "Cross-provider reasoning should be unencrypted (plain text)")
        }
      }
    }
  }
}
