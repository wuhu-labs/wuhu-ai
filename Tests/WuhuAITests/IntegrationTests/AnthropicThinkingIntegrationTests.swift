import Testing
import WuhuAI

struct AnthropicThinkingIntegrationTests {
  @Test func opus45ManualThinkingReplayChangesInputTokens() async throws {
    try await assertFollowUpReplayChangesInputTokens(
      scenario: .opus45ManualBudget2000,
      testName: #function,
    )
  }

  @Test func opus46AdaptiveThinkingReplayChangesInputTokens() async throws {
    try await assertFollowUpReplayChangesInputTokens(
      scenario: .opus46MinimalEffort,
      testName: #function,
    )
  }

  @Test func opus45ManualToolReplayChangesInputTokens() async throws {
    try await assertToolReplayChangesInputTokens(
      scenario: .opus45ManualBudget2000,
      testName: #function,
    )
  }

  @Test func opus46AdaptiveToolReplayChangesInputTokens() async throws {
    try await assertToolReplayChangesInputTokens(
      scenario: .opus46MinimalEffort,
      testName: #function,
    )
  }
}

private enum AnthropicThinkingScenario {
  case opus45ManualBudget2000
  case opus46MinimalEffort

  var model: Model {
    switch self {
    case .opus45ManualBudget2000:
      Model(id: "claude-opus-4-5", provider: .anthropic)
    case .opus46MinimalEffort:
      Model(id: "claude-opus-4-6", provider: .anthropic)
    }
  }

  var plainInitialPrompt: String {
    switch self {
    case .opus45ManualBudget2000:
      "Think before act. Give me a short answer about why the sky appears blue."
    case .opus46MinimalEffort:
      "Think before act. Find the smallest positive integer n such that n leaves remainders 1, 2, 3, 4, and 5 when divided by 2, 3, 4, 5, and 6 respectively. Answer briefly."
    }
  }

  var plainFollowUpPrompt: String {
    switch self {
    case .opus45ManualBudget2000:
      "Now answer the same question again in exactly one sentence."
    case .opus46MinimalEffort:
      "Now answer the same question again in exactly one sentence."
    }
  }

  var options: RequestOptions {
    switch self {
    case .opus45ManualBudget2000:
      RequestOptions(
        maxTokens: 4096,
        apiKey: "sidecar-placeholder",
        anthropicThinking: .init(mode: .manual, budgetTokens: 2000),
      )
    case .opus46MinimalEffort:
      RequestOptions(
        maxTokens: 4096,
        apiKey: "sidecar-placeholder",
        reasoningEffort: .minimal,
      )
    }
  }
}

private func assertFollowUpReplayChangesInputTokens(
  scenario: AnthropicThinkingScenario,
  testName: String,
  sourceFilePath: StaticString = #filePath,
) async throws {
  let recordingContext = try IntegrationTestRecordingContext(testName: testName, sourceFilePath: sourceFilePath)
  let provider = AnthropicMessagesProvider(fetch: recordingContext.fetchClient)

  let initialContext = Context(
    systemPrompt: "You are a concise assistant. Think carefully before answering.",
    messages: [
      .user(scenario.plainInitialPrompt),
    ]
  )

  let initial = try await finalMessage(
    from: provider,
    model: scenario.model,
    context: initialContext,
    options: scenario.options,
  )
  #expect(initial.content.contains(where: isReasoning))

  let followUpQuestion = Message.user(scenario.plainFollowUpPrompt)

  let replayedContext = Context(
    systemPrompt: initialContext.systemPrompt,
    messages: initialContext.messages + [.assistant(initial), followUpQuestion],
  )
  let replayed = try await finalMessage(
    from: provider,
    model: scenario.model,
    context: replayedContext,
    options: scenario.options,
  )

  let strippedAssistant = removingReasoning(from: initial)
  let strippedContext = Context(
    systemPrompt: initialContext.systemPrompt,
    messages: initialContext.messages + [.assistant(strippedAssistant), followUpQuestion],
  )
  let stripped = try await finalMessage(
    from: provider,
    model: scenario.model,
    context: strippedContext,
    options: scenario.options,
  )

  let replayedUsage = try #require(replayed.usage)
  let strippedUsage = try #require(stripped.usage)

  #expect(replayedUsage.inputTokens > strippedUsage.inputTokens)
}

private func assertToolReplayChangesInputTokens(
  scenario: AnthropicThinkingScenario,
  testName: String,
  sourceFilePath: StaticString = #filePath,
) async throws {
  let recordingContext = try IntegrationTestRecordingContext(testName: testName, sourceFilePath: sourceFilePath)
  let provider = AnthropicMessagesProvider(fetch: recordingContext.fetchClient)

  let tools: [Tool] = [
    .init(
      name: "lookup_weather",
      description: "Look up the weather for a city.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "city": .object([
            "type": .string("string"),
          ]),
        ]),
        "required": .array([.string("city")]),
      ])
    ),
  ]

  let initialContext = Context(
    systemPrompt: "You must call the lookup_weather tool before answering the user.",
    messages: [
      .user("Think before act. What is the weather in Tokyo right now?"),
    ],
    tools: tools,
  )

  let initial = try await finalMessage(
    from: provider,
    model: scenario.model,
    context: initialContext,
    options: scenario.options,
  )
  #expect(initial.content.contains(where: isReasoning))
  let toolCall = try #require(initial.content.compactMap(toolCall).first)

  let toolResult = Message.toolResult(.init(
    toolCallId: toolCall.id,
    toolName: toolCall.name,
    content: [.text("Tokyo weather: sunny, 28C")]
  ))

  let replayedContext = Context(
    systemPrompt: initialContext.systemPrompt,
    messages: initialContext.messages + [.assistant(initial), toolResult],
    tools: tools,
  )
  let replayed = try await finalMessage(
    from: provider,
    model: scenario.model,
    context: replayedContext,
    options: scenario.options,
  )

  let strippedAssistant = removingReasoning(from: initial)
  let strippedContext = Context(
    systemPrompt: initialContext.systemPrompt,
    messages: initialContext.messages + [.assistant(strippedAssistant), toolResult],
    tools: tools,
  )
  let stripped = try await finalMessage(
    from: provider,
    model: scenario.model,
    context: strippedContext,
    options: scenario.options,
  )

  let replayedUsage = try #require(replayed.usage)
  let strippedUsage = try #require(stripped.usage)

  #expect(replayedUsage.inputTokens > strippedUsage.inputTokens)
}

private func finalMessage(
  from provider: AnthropicMessagesProvider,
  model: Model,
  context: Context,
  options: RequestOptions,
) async throws -> AssistantMessage {
  let stream = try await provider.stream(model: model, context: context, options: options)
  var done: AssistantMessage?
  for try await event in stream {
    if case let .done(message) = event {
      done = message
    }
  }
  return try #require(done)
}

private func removingReasoning(from message: AssistantMessage) -> AssistantMessage {
  var copy = message
  copy.content.removeAll(where: isReasoning)
  return copy
}

private func isReasoning(_ block: ContentBlock) -> Bool {
  if case .reasoning = block { return true }
  return false
}

private func toolCall(_ block: ContentBlock) -> ToolCall? {
  if case let .toolCall(call) = block { return call }
  return nil
}
