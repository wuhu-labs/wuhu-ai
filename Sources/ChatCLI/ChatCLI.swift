import CFlush
import EffectLoops
import Foundation
import PiAI

// MARK: - ANSI helpers

enum ANSI {
  static let reset     = "\u{1b}[0m"
  static let bold      = "\u{1b}[1m"
  static let dim       = "\u{1b}[2m"
  static let cyan      = "\u{1b}[36m"
  static let green     = "\u{1b}[32m"
  static let red       = "\u{1b}[31m"
  static let clearLine = "\u{1b}[2K\r"
}

@inline(__always)
private func flushOutput() {
  cflush_stdout()
}

// MARK: - State & Actions

struct ChatState: Sendable {
  var messages: [(role: String, text: String)] = []
  var queue: [String] = []
  var isGenerating: Bool = false
}

enum ChatAction: Sendable {
  case enqueue(String)
  case streamDelta(String)
  case generationCompleted(String)
  case generationFailed(String)
  case eof
}

// MARK: - Behavior

struct ChatBehavior: LoopBehavior {
  let model: Model
  let apiKey: String
  let systemPrompt: String

  func reduce(state: inout ChatState, action: ChatAction) {
    switch action {
    case let .enqueue(text):
      state.queue.append(text)
    case .streamDelta:
      break // ephemeral, no state change
    case let .generationCompleted(text):
      state.messages.append((role: "assistant", text: text))
      state.isGenerating = false
    case let .generationFailed(error):
      state.messages.append((role: "error", text: error))
      state.isGenerating = false
    case .eof:
      break
    }
  }

  func nextEffect(state: inout ChatState) -> Effect<ChatAction>? {
    guard !state.isGenerating else { return nil }
    guard !state.queue.isEmpty else { return nil }

    let queued = state.queue
    state.queue = []
    for text in queued {
      state.messages.append((role: "user", text: text))
    }
    state.isGenerating = true

    let model = self.model
    let options = RequestOptions(apiKey: apiKey)
    let context = Context(
      systemPrompt: systemPrompt,
      messages: state.messages.map { msg in
        if msg.role == "user" {
          return .user(msg.text)
        } else {
          return .assistant(AssistantMessage(
            provider: .anthropic, model: model.id,
            content: [.text(msg.text)]
          ))
        }
      }
    )

    return Effect { send in
      do {
        let stream = try await PiAI.streamSimple(model: model, context: context, options: options)
        var fullText = ""
        for try await event in stream {
          switch event {
          case let .textDelta(delta, _):
            fullText += delta
            await send(.streamDelta(delta))
          case let .done(message):
            let text = message.content.compactMap { block -> String? in
              if case let .text(t) = block { return t.text }
              return nil
            }.joined()
            if !text.isEmpty { fullText = text }
          default:
            break
          }
        }
        await send(.generationCompleted(fullText.isEmpty ? "(empty response)" : fullText))
      } catch {
        await send(.generationFailed("\(error)"))
      }
    }
  }
}

// MARK: - Stdin reader (runs on a plain thread, feeds an AsyncStream)

func stdinLines(waitForPrompt: @escaping @Sendable () -> Void) -> AsyncStream<String> {
  AsyncStream { continuation in
    let thread = Thread {
      while true {
        waitForPrompt()
        print("\(ANSI.green)\(ANSI.bold)→\(ANSI.reset) ", terminator: "")
        cflush_stdout()
        guard let line = readLine(strippingNewline: true) else { break }
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
          continuation.yield(text)
        }
      }
      continuation.finish()
    }
    thread.start()
  }
}

// MARK: - Entry point

@main
struct ChatCLI {
  static func main() async throws {
    cflush_disable_buffering()

    guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !apiKey.isEmpty else {
      print("\(ANSI.red)Error: Set ANTHROPIC_API_KEY environment variable.\(ANSI.reset)")
      return
    }

    let behavior = ChatBehavior(
      model: Model(id: "claude-sonnet-4-6", provider: .anthropic),
      apiKey: apiKey,
      systemPrompt: "You are a helpful assistant. Be concise."
    )
    let loop = EffectLoop(behavior: behavior, initialState: ChatState())
    let (_, actions) = await loop.subscribe()
    let loopTask = Task { await loop.start() }

    print("\(ANSI.cyan)\(ANSI.bold)EffectLoops Chat\(ANSI.reset) \(ANSI.dim)· claude-sonnet-4-6\(ANSI.reset)")
    print("\(ANSI.dim)Type a message and press Enter. Ctrl-D to quit.\(ANSI.reset)\n")

    // Semaphore: stdin thread waits for permission to show prompt.
    // Starts at 1 so the first prompt appears immediately.
    let promptGate = DispatchSemaphore(value: 1)

    // Read stdin on a separate thread, feed into the loop
    let inputTask = Task {
      for await text in stdinLines(waitForPrompt: { promptGate.wait() }) {
        await loop.send(.enqueue(text))
      }
      await loop.send(.eof)
    }

    // Single render loop: all terminal output goes through here
    for await action in actions {
      switch action {
      case .enqueue:
        print("\(ANSI.cyan)\(ANSI.bold)◇\(ANSI.reset) ", terminator: "")
        flushOutput()

      case .streamDelta(let delta):
        print(delta, terminator: "")
        flushOutput()

      case .generationCompleted:
        print("\n")
        promptGate.signal()

      case .generationFailed(let error):
        print("\n\(ANSI.red)Error: \(error)\(ANSI.reset)\n")
        promptGate.signal()

      case .eof:
        break
      }
    }

    print("\(ANSI.dim)Goodbye.\(ANSI.reset)")
    loopTask.cancel()
    inputTask.cancel()
  }
}
