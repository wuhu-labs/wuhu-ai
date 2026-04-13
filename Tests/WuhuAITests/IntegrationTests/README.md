# Integration test recordings

These tests replay recorded Anthropic and OpenAI Codex API exchanges by default.

To record missing fixtures locally on macOS:

1. Copy `llm-forward-proxy.config.sample.json` to `llm-forward-proxy.config.json`.
2. Fill in the real upstream auth header values locally.
   - For Codex, you can grab an access token with:
     ```bash
     cat ~/.codex/auth.json | jq .tokens.access_token
     ```
3. Start the sidecar:
   ```bash
   python3 Tests/WuhuAITests/IntegrationTests/llm-forward-proxy.py
   ```
4. Record fixtures:
   ```bash
   WUHU_AI_RECORD_INTEGRATION_TESTS=1 swift test --filter AnthropicThinkingIntegrationTests
   WUHU_AI_RECORD_INTEGRATION_TESTS=1 swift test --filter OpenAICodexResponsesIntegrationTests
   ```

The checked-in recordings contain sanitized request headers only. Real API keys stay in the ignored local sidecar config and are injected only at recording time.
