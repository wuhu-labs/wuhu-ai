# wuhu-ai

**WuhuAI** — a unified Swift LLM client library built directly on top of `Fetch`.

Provides a single `LLMProvider` protocol with streaming support across multiple backends:

- **OpenAI** (Responses API)
- **OpenAI Codex** (Responses API, Codex-tuned)
- **Anthropic** (Messages API)

## Usage

```swift
import AsyncHTTPClient
import Fetch
import FetchAsyncHTTPClient
import WuhuAI

let provider = OpenAIResponsesProvider(fetch: .asyncHTTPClient(.shared))
let model = Model(id: "gpt-4.1-mini", provider: .openai)
let context = Context(messages: [
  .user("Say hello"),
])

let events = try await provider.stream(
  model: model,
  context: context,
  options: .init(apiKey: "sk-...")
)

for try await event in events {
  switch event {
  case let .textDelta(delta, _):
    print(delta, terminator: "")
  case let .done(message):
    print("\nTokens: \(String(describing: message.usage))")
  default:
    break
  }
}
```

## Adding as a Dependency

```swift
.package(url: "https://github.com/wuhu-labs/wuhu-ai.git", branch: "main")
.package(url: "https://github.com/wuhu-labs/wuhu-fetch.git", branch: "main")
.package(url: "https://github.com/wuhu-labs/wuhu-fetch-async-http-client.git", branch: "main")
```

Then depend on `WuhuAI` and the fetch transport you want:

```swift
.product(name: "WuhuAI", package: "wuhu-ai")
.product(name: "FetchAsyncHTTPClient", package: "wuhu-fetch-async-http-client")
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
