# wuhu-ai

**PiAI** — a unified Swift LLM client library.

Provides a single `LLMProvider` protocol with streaming support across multiple backends:

- **OpenAI** (Responses API)
- **OpenAI Codex** (Responses API, Codex-tuned)
- **Anthropic** (Messages API)

## Usage

```swift
import PiAI

let provider = OpenAIResponsesProvider(apiKey: "sk-...")
let events = try await provider.chatCompletionStream(
  messages: [.user("Say hello")],
  model: "gpt-4.1",
  options: .init()
)
for try await event in events {
  switch event {
  case .text(let chunk):
    print(chunk, terminator: "")
  case .finished(let usage):
    print("\nTokens: \(usage)")
  default:
    break
  }
}
```

## Adding as a Dependency

```swift
.package(url: "https://github.com/wuhu-labs/wuhu-ai.git", from: "0.1.0")
```

Then depend on the `PiAI` product:

```swift
.product(name: "PiAI", package: "wuhu-ai")
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
