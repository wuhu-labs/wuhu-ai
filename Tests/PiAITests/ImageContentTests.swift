import Foundation
import PiAI
import Testing

struct ImageContentTests {
    // MARK: - ImageContent type

    @Test func imageContentCanBeCreatedAndCompared() {
        let a = ImageContent(data: "aGVsbG8=", mimeType: "image/png")
        let b = ImageContent(data: "aGVsbG8=", mimeType: "image/png")
        let c = ImageContent(data: "d29ybGQ=", mimeType: "image/jpeg")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func imageContentBlockWorks() {
        let block = ContentBlock.image(data: "aGVsbG8=", mimeType: "image/png")
        if case let .image(img) = block {
            #expect(img.data == "aGVsbG8=")
            #expect(img.mimeType == "image/png")
        } else {
            Issue.record("Expected .image case")
        }
    }

    @Test func imageContentBlockEquality() {
        let a = ContentBlock.image(data: "aGVsbG8=", mimeType: "image/png")
        let b = ContentBlock.image(data: "aGVsbG8=", mimeType: "image/png")
        let c = ContentBlock.image(data: "d29ybGQ=", mimeType: "image/jpeg")
        #expect(a == b)
        #expect(a != c)
        #expect(a != ContentBlock.text("hello"))
    }

    // MARK: - Context round-trip (no crash)

    @Test func contextWithImageContentDoesNotCrash() {
        let context = Context(
            systemPrompt: "You are helpful.",
            messages: [
                .user(.init(content: [
                    .text("Look at this image:"),
                    .image(data: "aGVsbG8=", mimeType: "image/png"),
                ])),
            ]
        )
        #expect(context.messages.count == 1)
        if case let .user(m) = context.messages[0] {
            #expect(m.content.count == 2)
        } else {
            Issue.record("Expected user message")
        }
    }

    @Test func toolResultWithImageContentDoesNotCrash() {
        let context = Context(
            systemPrompt: nil,
            messages: [
                .user("Take a screenshot"),
                .assistant(.init(provider: .anthropic, model: "claude-sonnet-4-5", content: [
                    .toolCall(.init(id: "call_1", name: "screenshot", arguments: .object([:]))),
                ], stopReason: .toolUse)),
                .toolResult(.init(
                    toolCallId: "call_1",
                    toolName: "screenshot",
                    content: [
                        .text("Screenshot taken"),
                        .image(data: "c2NyZWVuc2hvdA==", mimeType: "image/png"),
                    ]
                )),
            ]
        )
        #expect(context.messages.count == 3)
    }

    // MARK: - Anthropic provider: user message with images

    @Test func anthropicUserMessageWithImage() async throws {
        let apiKey = "ak-test"

        let http = MockHTTPClient(sseHandler: { request in
            let body = try #require(request.body)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try #require(json["messages"] as? [[String: Any]])
            let first = try #require(messages.first)
            let content = try #require(first["content"] as? [[String: Any]])

            // Should have text + image blocks
            #expect(content.count == 2)

            let textBlock = content[0]
            #expect(textBlock["type"] as? String == "text")
            #expect(textBlock["text"] as? String == "Look at this")

            let imageBlock = content[1]
            #expect(imageBlock["type"] as? String == "image")
            let source = try #require(imageBlock["source"] as? [String: Any])
            #expect(source["type"] as? String == "base64")
            #expect(source["media_type"] as? String == "image/png")
            #expect(source["data"] as? String == "aGVsbG8=")

            return AsyncThrowingStream { continuation in
                continuation.yield(.init(event: "message_stop", data: #"{}"#))
                continuation.finish()
            }
        })

        let provider = AnthropicMessagesProvider(http: http)
        let model = Model(id: "claude-sonnet-4-5", provider: .anthropic)
        let context = Context(systemPrompt: "You are helpful.", messages: [
            .user(.init(content: [
                .text("Look at this"),
                .image(data: "aGVsbG8=", mimeType: "image/png"),
            ])),
        ])

        let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: apiKey))
        for try await _ in stream {}
    }

    @Test func anthropicUserMessageImageOnlyGetsFallbackText() async throws {
        let apiKey = "ak-test"

        let http = MockHTTPClient(sseHandler: { request in
            let body = try #require(request.body)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try #require(json["messages"] as? [[String: Any]])
            let first = try #require(messages.first)
            let content = try #require(first["content"] as? [[String: Any]])

            // Should have fallback text + image
            #expect(content.count == 2)
            #expect(content[0]["text"] as? String == "(see attached image)")

            return AsyncThrowingStream { continuation in
                continuation.yield(.init(event: "message_stop", data: #"{}"#))
                continuation.finish()
            }
        })

        let provider = AnthropicMessagesProvider(http: http)
        let model = Model(id: "claude-sonnet-4-5", provider: .anthropic)
        let context = Context(systemPrompt: "You are helpful.", messages: [
            .user(.init(content: [
                .image(data: "aGVsbG8=", mimeType: "image/jpeg"),
            ])),
        ])

        let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: apiKey))
        for try await _ in stream {}
    }

    // MARK: - Anthropic provider: tool result with images

    @Test func anthropicToolResultWithImageUsesArrayContent() async throws {
        let apiKey = "ak-test"

        let http = MockHTTPClient(sseHandler: { request in
            let body = try #require(request.body)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try #require(json["messages"] as? [[String: Any]])

            // Find the tool_result message (in a "user" role wrapper)
            let toolResultMsg = messages.first(where: { msg in
                guard let content = msg["content"] as? [[String: Any]] else { return false }
                return content.contains(where: { ($0["type"] as? String) == "tool_result" })
            })
            let toolMsg = try #require(toolResultMsg)
            let content = try #require(toolMsg["content"] as? [[String: Any]])
            let toolResult = try #require(content.first(where: { ($0["type"] as? String) == "tool_result" }))

            // content should be an array (not string) when images present
            let toolContent = try #require(toolResult["content"] as? [[String: Any]])
            #expect(toolContent.count == 2) // text + image

            let textBlock = toolContent[0]
            #expect(textBlock["type"] as? String == "text")
            #expect(textBlock["text"] as? String == "Screenshot result")

            let imageBlock = toolContent[1]
            #expect(imageBlock["type"] as? String == "image")

            return AsyncThrowingStream { continuation in
                continuation.yield(.init(event: "message_stop", data: #"{}"#))
                continuation.finish()
            }
        })

        let provider = AnthropicMessagesProvider(http: http)
        let model = Model(id: "claude-sonnet-4-5", provider: .anthropic)
        let context = Context(systemPrompt: nil, messages: [
            .user("Take a screenshot"),
            .assistant(.init(provider: .anthropic, model: "claude-sonnet-4-5", content: [
                .toolCall(.init(id: "call_1", name: "screenshot", arguments: .object([:]))),
            ], stopReason: .toolUse)),
            .toolResult(.init(
                toolCallId: "call_1",
                toolName: "screenshot",
                content: [
                    .text("Screenshot result"),
                    .image(data: "c2NyZWVuc2hvdA==", mimeType: "image/png"),
                ]
            )),
        ])

        let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: apiKey))
        for try await _ in stream {}
    }

    @Test func anthropicToolResultWithoutImageUsesStringContent() async throws {
        let apiKey = "ak-test"

        let http = MockHTTPClient(sseHandler: { request in
            let body = try #require(request.body)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try #require(json["messages"] as? [[String: Any]])

            let toolResultMsg = messages.first(where: { msg in
                guard let content = msg["content"] as? [[String: Any]] else { return false }
                return content.contains(where: { ($0["type"] as? String) == "tool_result" })
            })
            let toolMsg = try #require(toolResultMsg)
            let content = try #require(toolMsg["content"] as? [[String: Any]])
            let toolResult = try #require(content.first(where: { ($0["type"] as? String) == "tool_result" }))

            // content should be a string when no images
            let stringContent = try #require(toolResult["content"] as? String)
            #expect(stringContent == "Some text output")

            return AsyncThrowingStream { continuation in
                continuation.yield(.init(event: "message_stop", data: #"{}"#))
                continuation.finish()
            }
        })

        let provider = AnthropicMessagesProvider(http: http)
        let model = Model(id: "claude-sonnet-4-5", provider: .anthropic)
        let context = Context(systemPrompt: nil, messages: [
            .user("Run tool"),
            .assistant(.init(provider: .anthropic, model: "claude-sonnet-4-5", content: [
                .toolCall(.init(id: "call_1", name: "tool", arguments: .object([:]))),
            ], stopReason: .toolUse)),
            .toolResult(.init(
                toolCallId: "call_1",
                toolName: "tool",
                content: [.text("Some text output")]
            )),
        ])

        let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: apiKey))
        for try await _ in stream {}
    }

    // MARK: - OpenAI provider: user message with images

    @Test func openaiUserMessageWithImage() async throws {
        let apiKey = "sk-test"

        let http = MockHTTPClient(sseHandler: { request in
            let body = try #require(request.body)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let input = try #require(json["input"] as? [[String: Any]])

            // Find user message (skip system)
            let userMsg = input.first(where: { ($0["role"] as? String) == "user" })
            let msg = try #require(userMsg)
            let content = try #require(msg["content"] as? [[String: Any]])

            // Should have input_text + input_image
            #expect(content.count == 2)
            #expect(content[0]["type"] as? String == "input_text")
            #expect(content[0]["text"] as? String == "Look at this")
            #expect(content[1]["type"] as? String == "input_image")
            #expect(content[1]["detail"] as? String == "auto")
            #expect(content[1]["image_url"] as? String == "data:image/png;base64,aGVsbG8=")

            return AsyncThrowingStream { continuation in
                continuation.yield(.init(data: #"{"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}"#))
                continuation.finish()
            }
        })

        let provider = OpenAIResponsesProvider(http: http)
        let model = Model(id: "gpt-4.1-mini", provider: .openai)
        let context = Context(systemPrompt: "You are helpful.", messages: [
            .user(.init(content: [
                .text("Look at this"),
                .image(data: "aGVsbG8=", mimeType: "image/png"),
            ])),
        ])

        let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: apiKey))
        for try await _ in stream {}
    }

    // MARK: - OpenAI provider: tool result with images injects follow-up user message

    @Test func openaiToolResultWithImageInjectsFollowUp() async throws {
        let apiKey = "sk-test"

        let http = MockHTTPClient(sseHandler: { request in
            let body = try #require(request.body)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let input = try #require(json["input"] as? [[String: Any]])

            // Find function_call_output
            let fcoIndex = input.firstIndex(where: { ($0["type"] as? String) == "function_call_output" })
            let idx = try #require(fcoIndex)
            let fco = input[idx]
            #expect(fco["output"] as? String == "Screenshot result")

            // Next entry should be a follow-up user message with image
            #expect(idx + 1 < input.count)
            let followUp = input[idx + 1]
            #expect(followUp["role"] as? String == "user")
            let content = try #require(followUp["content"] as? [[String: Any]])
            #expect(content.count == 2) // input_text + input_image
            #expect(content[0]["type"] as? String == "input_text")
            #expect(content[0]["text"] as? String == "Attached image(s) from tool result:")
            #expect(content[1]["type"] as? String == "input_image")
            #expect(content[1]["image_url"] as? String == "data:image/png;base64,c2NyZWVuc2hvdA==")

            return AsyncThrowingStream { continuation in
                continuation.yield(.init(data: #"{"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}"#))
                continuation.finish()
            }
        })

        let provider = OpenAIResponsesProvider(http: http)
        let model = Model(id: "gpt-4.1-mini", provider: .openai)
        let context = Context(systemPrompt: nil, messages: [
            .user("Take a screenshot"),
            .assistant(.init(provider: .openai, model: "gpt-4.1-mini", content: [
                .toolCall(.init(id: "call_1", name: "screenshot", arguments: .object([:]))),
            ], stopReason: .toolUse)),
            .toolResult(.init(
                toolCallId: "call_1",
                toolName: "screenshot",
                content: [
                    .text("Screenshot result"),
                    .image(data: "c2NyZWVuc2hvdA==", mimeType: "image/png"),
                ]
            )),
        ])

        let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: apiKey))
        for try await _ in stream {}
    }

    @Test func openaiToolResultImageOnlyUsesFallbackText() async throws {
        let apiKey = "sk-test"

        let http = MockHTTPClient(sseHandler: { request in
            let body = try #require(request.body)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let input = try #require(json["input"] as? [[String: Any]])

            let fco = input.first(where: { ($0["type"] as? String) == "function_call_output" })
            let entry = try #require(fco)
            #expect(entry["output"] as? String == "(see attached image)")

            return AsyncThrowingStream { continuation in
                continuation.yield(.init(data: #"{"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}"#))
                continuation.finish()
            }
        })

        let provider = OpenAIResponsesProvider(http: http)
        let model = Model(id: "gpt-4.1-mini", provider: .openai)
        let context = Context(systemPrompt: nil, messages: [
            .user("Take a screenshot"),
            .assistant(.init(provider: .openai, model: "gpt-4.1-mini", content: [
                .toolCall(.init(id: "call_1", name: "screenshot", arguments: .object([:]))),
            ], stopReason: .toolUse)),
            .toolResult(.init(
                toolCallId: "call_1",
                toolName: "screenshot",
                content: [
                    .image(data: "c2NyZWVuc2hvdA==", mimeType: "image/png"),
                ]
            )),
        ])

        let stream = try await provider.stream(model: model, context: context, options: .init(apiKey: apiKey))
        for try await _ in stream {}
    }
}
