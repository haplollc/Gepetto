//
//  AIEngine.swift
//  Gepetto
//
//  Pluggable AI backend protocol. Anyone driving Gepetto can implement this
//  for the model of their choice — local Llama / MLX, Apple Foundation
//  Models, OpenAI, Anthropic, Gemini, Mistral, anything with a streaming
//  text completion. The agent loop calls only `stream(...)`.
//

import Foundation

// MARK: - Protocol

/// A pluggable AI backend that produces a streaming text completion for a
/// chat-style conversation.
///
/// Implementations should:
/// - Honor `systemPrompt` if non-nil (route it to the system role for APIs
///   that support it, or prepend it to the first user message).
/// - Stream every text chunk as it arrives.
/// - Finish the stream cleanly when the model is done.
/// - Throw on transport / decode errors so the agent can surface them.
public protocol GepettoAIEngine: AnyObject, Sendable {
    /// Stream a completion for the given conversation.
    /// - Parameters:
    ///   - messages: ordered conversation turns (user / assistant / system).
    ///   - systemPrompt: optional dedicated system prompt for this turn.
    ///     Engines may merge this with `messages` containing role `.system`.
    /// - Returns: an `AsyncThrowingStream<String, Error>` of text deltas.
    func stream(
        messages: [GepettoMessage],
        systemPrompt: String?
    ) -> AsyncThrowingStream<String, Error>
}

// MARK: - Message

/// A single conversation turn the agent uses to talk to a `GepettoAIEngine`.
public struct GepettoMessage: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable, Equatable {
        case user
        case assistant
        case system
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    /// Convenience: a user-role message.
    public static func user(_ content: String) -> GepettoMessage {
        GepettoMessage(role: .user, content: content)
    }

    /// Convenience: an assistant-role message.
    public static func assistant(_ content: String) -> GepettoMessage {
        GepettoMessage(role: .assistant, content: content)
    }

    /// Convenience: a system-role message.
    public static func system(_ content: String) -> GepettoMessage {
        GepettoMessage(role: .system, content: content)
    }
}

// MARK: - Convenience: collect a stream into a full string

extension GepettoAIEngine {
    /// Collect the full streamed response into a single string. Useful for
    /// validators / one-shot decisions where streaming isn't needed.
    public func complete(
        messages: [GepettoMessage],
        systemPrompt: String? = nil
    ) async throws -> String {
        var out = ""
        for try await chunk in stream(messages: messages, systemPrompt: systemPrompt) {
            out += chunk
        }
        return out
    }
}
