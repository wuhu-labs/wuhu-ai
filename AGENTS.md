# wuhu-ai — Agent Instructions

## Adding a new provider

When you add a new LLM provider dialect:

1. Add the provider's auth header name to `sensitiveHeaderNames` in
   `Tests/WuhuAITests/TestHelpers/RecordingContext.swift` **before recording any fixtures.**

   The sanitization list currently covers:
   - `authorization`
   - `x-api-key`
   - `chatgpt-account-id`
   - `x-goog-api-key`

   Without this, the raw API key will be committed to the repo in the
   `.request.json` fixture files. Google and other providers actively
   scan for leaked keys and will revoke them.

2. Record fixtures with `RECORDING=1` and the relevant `*_API_KEY` env var:
   ```
   RECORDING=1 GEMINI_API_KEY=... swift test --filter YourTest
   ```

3. Verify the fixture `.request.json` files contain `HMAC:SHA256:...` for
   the auth header, **not** a raw key.

## Running tests

Recordings are **reproducibility aids**, not a substitute for assertions.
Every integration test must include `#expect`/`#require` on the actual
behavior (tool call arguments, response content, etc.), not just rely on
the recording comparison to catch regressions.

- Unit tests: `swift test --filter UnitTests`
- Integration tests (replay mode, no network): `swift test --filter IntegrationTests`
- Integration tests (record mode): `RECORDING=1 swift test --filter IntegrationTests`
