import EffectLoops
import PiAI

// MARK: - ChatGPT-style chat with a queue

// The simplest possible loop: user messages queue up, the loop
// infers one at a time, appends the assistant response. No tools,
// no persistence, no crash recovery. Pure in-memory.

// MARK: State

struct ChatState: Sendable {
  var messages: [Message] = []
  var queue: [String] = []
  var isGenerating: Bool = false
}

// MARK: Action

enum ChatAction: Sendable {
  /// External: user enqueued a message.
  case enqueue(String)
  /// Internal: generation completed.
  case generationCompleted(AssistantMessage)
  /// Internal: generation failed.
  case generationFailed(String)
}

// MARK: Behavior

struct ChatBehavior: LoopBehavior {
  let model: Model
  let systemPrompt: String

  func reduce(state: inout ChatState, action: ChatAction) {
    switch action {
    case let .enqueue(text):
      state.queue.append(text)

    case let .generationCompleted(message):
      state.messages.append(.assistant(message))
      state.isGenerating = false

    case let .generationFailed(error):
      // Append as a synthetic assistant message so the user sees it.
      state.messages.append(.assistant(AssistantMessage(
        provider: .openai, model: "error",
        content: [.text("Error: \(error)")]
      )))
      state.isGenerating = false
    }
  }

  func nextEffect(state: inout ChatState) -> Effect<ChatAction>? {
    // Don't double-infer.
    guard !state.isGenerating else { return nil }

    // Drain all queued messages into the transcript.
    guard !state.queue.isEmpty else { return nil }
    let queued = state.queue
    state.queue = []
    for text in queued {
      state.messages.append(.user(text))
    }

    // Start inference.
    state.isGenerating = true
    let context = Context(
      systemPrompt: systemPrompt,
      messages: state.messages
    )
    let model = self.model

    return Effect { send in
      let stream = try await PiAI.streamSimple(model: model, context: context)
      var final: AssistantMessage?
      for try await event in stream {
        if case let .done(message) = event {
          final = message
        }
      }
      if let message = final {
        await send(.generationCompleted(message))
      } else {
        await send(.generationFailed("No response from model"))
      }
    }
  }
}
