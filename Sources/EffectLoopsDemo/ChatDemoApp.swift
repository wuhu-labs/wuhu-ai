import EffectLoops
import Observation
import PiAI
import TUIkit

// MARK: - Chat State & Actions (reuses EffectLoopsExamples.ChatBehavior pattern)

struct ChatState: Sendable {
    var messages: [ChatMessage] = []
    var queue: [String] = []
    var isGenerating: Bool = false
    var streamBuffer: String = ""
}

struct ChatMessage: Sendable, Identifiable {
    let id: Int
    let role: Role
    let text: String

    enum Role: Sendable { case user, assistant, error }
}

enum ChatAction: Sendable {
    case enqueue(String)
    case streamDelta(String)
    case generationCompleted(String)
    case generationFailed(String)
}

// MARK: - Chat Behavior

struct ChatBehavior: LoopBehavior {
    let model: Model
    let apiKey: String
    let systemPrompt: String

    func reduce(state: inout ChatState, action: ChatAction) {
        switch action {
        case let .enqueue(text):
            state.queue.append(text)

        case let .streamDelta(delta):
            state.streamBuffer += delta

        case let .generationCompleted(text):
            state.messages.append(ChatMessage(
                id: state.messages.count,
                role: .assistant,
                text: text
            ))
            state.isGenerating = false
            state.streamBuffer = ""

        case let .generationFailed(error):
            state.messages.append(ChatMessage(
                id: state.messages.count,
                role: .error,
                text: error
            ))
            state.isGenerating = false
            state.streamBuffer = ""
        }
    }

    func nextEffect(state: inout ChatState) -> Effect<ChatAction>? {
        guard !state.isGenerating else { return nil }
        guard !state.queue.isEmpty else { return nil }

        let queued = state.queue
        state.queue = []
        for text in queued {
            state.messages.append(ChatMessage(
                id: state.messages.count,
                role: .user,
                text: text
            ))
        }
        state.isGenerating = true
        state.streamBuffer = ""

        let model = self.model
        let options = RequestOptions(apiKey: apiKey)
        let context = Context(
            systemPrompt: systemPrompt,
            messages: state.messages.map { msg in
                switch msg.role {
                case .user:
                    return .user(msg.text)
                case .assistant, .error:
                    return .assistant(AssistantMessage(
                        provider: .anthropic, model: model.id,
                        content: [.text(msg.text)]
                    ))
                }
            }
        )

        return Effect { send in
            do {
                let stream = try await PiAI.streamSimple(
                    model: model, context: context, options: options
                )
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
                await send(.generationCompleted(
                    fullText.isEmpty ? "(empty response)" : fullText
                ))
            } catch {
                await send(.generationFailed("\(error)"))
            }
        }
    }
}

// MARK: - View Model bridging EffectLoop → TUIkit

@Observable
@MainActor
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var queueCount: Int = 0
    var isGenerating: Bool = false
    var streamBuffer: String = ""

    private var loop: EffectLoop<ChatBehavior>?
    private var observeTask: Task<Void, Never>?

    func start(apiKey: String) {
        let behavior = ChatBehavior(
            model: Model(id: "claude-sonnet-4-6", provider: .anthropic),
            apiKey: apiKey,
            systemPrompt: "You are a helpful assistant. Be concise."
        )
        let loop = EffectLoop(behavior: behavior, initialState: ChatState())
        self.loop = loop

        observeTask = Task { [weak self] in
            let (_, actions) = await loop.subscribe()
            Task { await loop.start() }
            for await _ in actions {
                guard let self else { return }
                let state = await loop.state
                self.messages = state.messages
                self.queueCount = state.queue.count
                self.isGenerating = state.isGenerating
                self.streamBuffer = state.streamBuffer
            }
        }
    }

    func stop() {
        observeTask?.cancel()
        observeTask = nil
        loop = nil
    }

    func send(_ text: String) {
        guard let loop else { return }
        Task { await loop.send(.enqueue(text)) }
    }
}

// MARK: - TUIkit App

@main
struct ChatDemoApp: TUIkit.App {
    var body: some Scene {
        WindowGroup {
            ChatView()
        }
    }
}

// MARK: - Chat View

struct ChatView: View {
    @State var vm = ChatViewModel()
    @State var inputText: String = ""
    @State var apiKey: String = ""
    @State var started: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──
            Text("EffectLoops Chat Demo")
                .bold()
                .foregroundStyle(.cyan)

            Text("claude-sonnet-4-6 · TUIkit + EffectLoops")
                .dim()

            Divider()

            // ── Message history ──
            if vm.messages.isEmpty && !vm.isGenerating {
                Spacer()
                Text("No messages yet. Type below to start chatting.")
                    .dim()
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(vm.messages, id: \.id) { msg in
                        messageRow(msg)
                    }

                    // Streaming indicator
                    if vm.isGenerating {
                        HStack(spacing: 1) {
                            Text("◇")
                                .bold()
                                .foregroundStyle(.cyan)
                            if vm.streamBuffer.isEmpty {
                                Spinner()
                            } else {
                                Text(vm.streamBuffer)
                            }
                        }
                    }

                    Spacer()
                }
            }

            // ── Queue indicator ──
            if vm.queueCount > 0 {
                Text("\(vm.queueCount) message(s) queued")
                    .foregroundStyle(.yellow)
            }

            Divider()

            // ── Input ──
            HStack(spacing: 1) {
                Text("→").bold().foregroundStyle(.green)
                TextField("Message", text: $inputText, prompt: Text("Type a message..."))
                    .onSubmit {
                        let text = inputText.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        guard !text.isEmpty else { return }
                        if !started {
                            // First submission — treat as API key if env not set
                            if apiKey.isEmpty {
                                apiKey = text
                                vm.start(apiKey: apiKey)
                                started = true
                            }
                        } else {
                            vm.send(text)
                        }
                        inputText = ""
                    }
            }
        }
        .padding(.horizontal, 1)
        .onAppear {
            if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
               !key.isEmpty
            {
                apiKey = key
                vm.start(apiKey: key)
                started = true
            }
        }
        .statusBarItems {
            StatusBarItem(shortcut: Shortcut.enter, label: "send")
            StatusBarItem(
                shortcut: Shortcut.escape,
                label: started ? "quit" : "enter API key first"
            )
        }
        .appHeader {
            HStack(spacing: 2) {
                Text("EffectLoops Chat").bold()
                if vm.isGenerating {
                    Spinner()
                }
            }
        }
    }

    @ViewBuilder
    func messageRow(_ msg: ChatMessage) -> some View {
        switch msg.role {
        case .user:
            HStack(spacing: 1) {
                Text("→").bold().foregroundStyle(.green)
                Text(msg.text)
            }
        case .assistant:
            HStack(spacing: 1) {
                Text("◇").bold().foregroundStyle(.cyan)
                Text(msg.text)
            }
        case .error:
            HStack(spacing: 1) {
                Text("✗").bold().foregroundStyle(.red)
                Text(msg.text).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Foundation import for ProcessInfo

import Foundation
