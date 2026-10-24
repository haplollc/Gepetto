//
//  FoundationModelsEngine.swift
//  Gepetto
//
//  Drives Gepetto with Apple Intelligence: Apple's on-device language model
//  through the Foundation Models framework. Nothing leaves the device.
//
//  The model reads 4,096 tokens for the prompt and the reply together, so
//  the engine is prompt-limited: before every step the agent asks
//  `promptFits` and shows the model less of the page until the prompt leaves
//  room for a reply. Token counts are exact where the system can count them
//  (iOS and macOS 26.4 and later) and a cautious estimate before that.
//
//  Each step is a fresh session, since the agent's prompt carries the whole
//  state of the run, and replies are decoded greedily so the JSON is stable
//  from one run to the next. Web pages are text the person asked the agent
//  to read, so the permissive content-transformation guardrails are used:
//  an article about a war or a medicine is not a reason to stop.
//

#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public final class FoundationModelsEngine: GepettoPromptLimitedEngine, @unchecked Sendable {

    /// Tokens kept free for the reply. A step reply is about 100 tokens; a
    /// final answer that summarises a page runs longer.
    public let replyTokens: Int

    /// Added to the engine's instructions, for example the language the
    /// person reads ("Write the answer in French.").
    public let extraInstructions: String?

    private let model: SystemLanguageModel
    private let lock = NSLock()
    private var inFlight: Task<Void, Never>?

    public init(replyTokens: Int = 600, extraInstructions: String? = nil) {
        self.replyTokens = replyTokens
        self.extraInstructions = extraInstructions
        self.model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    // MARK: Availability

    /// True when Apple Intelligence can run on this device right now.
    public static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Why Apple Intelligence cannot run right now, written for the person,
    /// or nil when it can.
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in Settings to use the browser with it."
            case .deviceNotEligible:
                return "This device does not support Apple Intelligence."
            case .modelNotReady:
                return "Apple Intelligence is still getting ready. Try again in a few minutes."
            @unknown default:
                return "Apple Intelligence is not available right now."
            }
        }
    }

    // MARK: Prompt

    static let controllerInstructions =
        "You are the controller of a browser automation agent. Each turn, reply with exactly one JSON object in the format the prompt shows, with every key and action name written in English as given. Reply with the JSON object only: no Markdown, no code fences, no text before or after it."

    private func instructions(systemPrompt: String?) -> String {
        var parts = [Self.controllerInstructions]
        if let extra = extraInstructions, !extra.isEmpty { parts.append(extra) }
        if let systemPrompt, !systemPrompt.isEmpty { parts.append(systemPrompt) }
        return parts.joined(separator: "\n\n")
    }

    /// The agent sends one user turn per step. Anything before it is folded
    /// into the prompt as earlier conversation, so no turn is dropped.
    static func prompt(from messages: [GepettoMessage]) -> String {
        guard let last = messages.last else { return "" }
        let earlier = messages.dropLast().filter { !$0.content.isEmpty }
        guard !earlier.isEmpty else { return last.content }
        let lines = earlier.map { m -> String in
            switch m.role {
            case .user: return "User: \(m.content)"
            case .assistant: return "Assistant: \(m.content)"
            case .system: return m.content
            }
        }
        return "EARLIER CONVERSATION:\n" + lines.joined(separator: "\n") + "\n\n" + last.content
    }

    // MARK: GepettoPromptLimitedEngine

    public func promptFits(_ prompt: String) async -> Bool {
        await promptTokens(prompt) + replyTokens <= model.contextSize
    }

    /// Tokens the prompt and the engine's instructions take. Exact where the
    /// system can count; otherwise about one token per three characters,
    /// which overestimates English prose and fits page listings.
    func promptTokens(_ prompt: String) async -> Int {
        let instructions = instructions(systemPrompt: nil)
        // The chat template wraps each turn in a few tokens of its own.
        let template = 24
        if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
            if let a = try? await model.tokenCount(for: Instructions(instructions)),
               let b = try? await model.tokenCount(for: prompt) {
                return a + b + template
            }
        }
        return (instructions.count + prompt.count) / 3 + template
    }

    // MARK: GepettoAIEngine

    public func stream(messages: [GepettoMessage], systemPrompt: String?) -> AsyncThrowingStream<String, Error> {
        let prompt = Self.prompt(from: messages)
        let instructions = instructions(systemPrompt: systemPrompt)
        let model = self.model
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: replyTokens)

        return AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    var sent = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        if Task.isCancelled { break }
                        let text = snapshot.content
                        // Snapshots hold the whole reply so far; pass on what is new.
                        guard text.count > sent.count, text.hasPrefix(sent) else { continue }
                        continuation.yield(String(text.dropFirst(sent.count)))
                        sent = text
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: Failure(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            self.lock.withLock { self.inFlight = task }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    /// Cut the model call in flight, if any. The agent loop then sees its
    /// stream end and acts on its own stop flag. Safe to call at any time.
    public func cancelInFlightGeneration() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            defer { inFlight = nil }
            return inFlight
        }
        task?.cancel()
    }

    // MARK: Errors

    /// A model call that ended without a reply, in words for the person.
    public struct Failure: LocalizedError, Sendable {
        public let message: String

        init(_ error: LanguageModelSession.GenerationError) {
            switch error {
            case .exceededContextWindowSize:
                message = "This page is too long for Apple Intelligence to read."
            case .assetsUnavailable:
                message = "Apple Intelligence is still getting ready. Try again in a few minutes."
            case .guardrailViolation:
                message = "Apple Intelligence declined to read this page."
            case .unsupportedLanguageOrLocale:
                message = "Apple Intelligence does not support this language yet."
            case .rateLimited, .concurrentRequests:
                message = "Apple Intelligence is busy right now. Try again in a moment."
            case .refusal:
                message = "Apple Intelligence declined this step."
            default:
                message = "Apple Intelligence could not reply: \(error.localizedDescription)"
            }
        }

        public var errorDescription: String? { message }
    }
}
#endif
