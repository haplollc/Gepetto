//
//  BrowserAgent.swift
//  Gepetto
//
//  High-level agent that drives a real WKWebView via the browser tool from a
//  pluggable AI backend (`GepettoAIEngine`). One public method — `run(task:)`.
//
//  Features baked in:
//   - Headless host: parents the WKWebView in a hidden UIWindow / NSWindow
//     with a real viewport so `innerText` / `takeSnapshot` work without UI.
//   - Multi-stage automation: a single prompt with multiple URLs is parsed
//     into ordered (URL + form-fill + submit) stages and driven
//     deterministically.
//   - Form-fill takeover: extracts real form selectors and fills by name /
//     type / placeholder heuristics so weak models can complete forms.
//   - Auto-content-click: when the user says "click into the top story"
//     etc., picks the first external content link and navigates.
//   - Per-stage AI validation: after every navigate / form-fill, the agent
//     asks the AI engine "did this stage succeed?" and aborts on failure
//     instead of plowing through bad state.
//   - Refusal detection + nudge + deterministic takeover for weak local LLMs.
//
//  See the README for usage examples.
//

import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Agent phases

/// Coarse-grained activity the agent is performing right now. SwiftUI views
/// bind to `BrowserAgent.currentPhase` so the user always knows *what* the
/// agent is doing — thinking, reading, typing, validating, etc.
public enum AgentPhase: Sendable, Equatable {
    case idle
    case starting
    case navigating(url: String)
    case readingPage
    case thinking          // waiting on the AI stream
    case typing(field: String, value: String)
    case clicking(target: String)
    case scrolling(direction: String)
    case submitting
    case extracting        // extract_text / extract_links / extract_forms
    case takingScreenshot
    case runningJS
    case validating
    case recovering(attempt: Int)
    case summarizing       // streaming the final answer
    case finished
    case failed(String)

    public var label: String {
        switch self {
        case .idle:                       return "Idle"
        case .starting:                   return "Starting…"
        case .navigating(let url):        return "Loading \(prettyHost(url))"
        case .readingPage:                return "Reading page…"
        case .thinking:                   return "Thinking…"
        case .typing(let field, _):       return "Typing \(field)…"
        case .clicking(let target):       return "Clicking \(target.prefix(40))…"
        case .scrolling(let dir):         return "Scrolling \(dir)…"
        case .submitting:                 return "Submitting…"
        case .extracting:                 return "Extracting…"
        case .takingScreenshot:           return "Capturing…"
        case .runningJS:                  return "Running JS…"
        case .validating:                 return "Checking result…"
        case .recovering(let n):          return "Trying a fix… (attempt \(n))"
        case .summarizing:                return "Writing answer…"
        case .finished:                   return "Done"
        case .failed(let reason):         return "Failed: \(reason.prefix(60))"
        }
    }

    public var detail: String? {
        switch self {
        case .navigating(let url):     return url
        case .typing(_, let value):    return String(value.prefix(60))
        case .clicking(let target):    return target
        case .scrolling(let dir):      return dir
        case .recovering:              return "asking the AI for a corrective action"
        case .thinking, .summarizing:  return "waiting on AI response"
        case .readingPage, .extracting: return "running JS in the page"
        case .validating:              return "asking the AI to verify the page"
        default:                       return nil
        }
    }

    public var symbol: String {
        switch self {
        case .idle, .finished:    return "circle"
        case .starting:           return "power"
        case .navigating:         return "arrow.up.right.square"
        case .readingPage:        return "doc.plaintext"
        case .thinking:           return "brain"
        case .typing:             return "keyboard"
        case .clicking:           return "hand.tap"
        case .scrolling:          return "arrow.up.and.down"
        case .submitting:         return "paperplane"
        case .extracting:         return "list.bullet.rectangle"
        case .takingScreenshot:   return "camera"
        case .runningJS:          return "curlybraces"
        case .validating:         return "checkmark.seal"
        case .recovering:         return "arrow.triangle.2.circlepath"
        case .summarizing:        return "text.bubble"
        case .failed:             return "exclamationmark.triangle"
        }
    }

    private func prettyHost(_ url: String) -> String {
        guard let u = URL(string: url), let host = u.host else { return url }
        return host.replacingOccurrences(of: "www.", with: "")
    }
}

// MARK: - Public events

public enum BrowserAgentEvent: Sendable {
    /// Streaming partial text from the AI, with tool_call markup stripped.
    case textChunk(String)
    /// Wipe the in-progress assistant message and replace with this text.
    case replaceText(String)
    /// AI decided to call a browser action.
    case action(name: String, arguments: [String: Any])
    /// Action finished — `summary` is the result we'd feed back to the AI.
    case actionResult(summary: String, success: Bool)
    /// Per-stage validation outcome (only emitted when validation is on).
    case validation(stageIndex: Int, success: Bool, reason: String)
    /// The agent is attempting to recover from a stage failure by asking the
    /// AI for a corrective action (e.g. shorter title, click "OK" to dismiss
    /// an error, navigate elsewhere). Emitted before the recovery action runs.
    case recovering(stageIndex: Int, attempt: Int, plan: String)
    /// Agent finished cleanly with a final natural-language answer.
    case complete(finalText: String)
    /// Agent failed (bad output, max iterations, validation failure, etc.).
    case failed(reason: String, partialText: String)
}

// MARK: - Configuration

public struct BrowserAgentConfiguration: Sendable {
    /// Maximum number of agent-loop iterations for the free-form (single
    /// stage) path before bailing.
    public var maxIterations: Int

    /// When true, the agent asks the AI engine to validate the result page
    /// after each automation stage. Costs an extra round-trip per stage but
    /// catches silent failures (e.g. login showed an error but the agent
    /// proceeded anyway).
    public var validateEachStage: Bool

    /// Pause between actions so the user can watch the live webview update.
    /// 0 = no pause.
    public var visualPaceMs: Int

    /// Hidden host viewport. Pages won't render correctly with frame .zero.
    public var headlessViewport: CGSize

    /// When a stage fails validation, the agent asks the AI engine for a
    /// corrective action (e.g. retry the form with a shorter title) and
    /// retries up to this many times before giving up. Set to 0 to disable
    /// recovery entirely.
    public var maxStageRecoveries: Int

    /// Pause inserted BEFORE every stage after the first in a multi-stage
    /// script. Sites with rate-limits (Hacker News, login-then-post flows,
    /// etc.) frequently reject back-to-back actions; this gives them
    /// breathing room. Set to 0 to disable.
    public var betweenStagesDelayMs: Int

    public init(
        maxIterations: Int = 8,
        validateEachStage: Bool = true,
        visualPaceMs: Int = 700,
        headlessViewport: CGSize = CGSize(width: 1024, height: 1366),
        maxStageRecoveries: Int = 2,
        betweenStagesDelayMs: Int = 2000
    ) {
        self.maxIterations = maxIterations
        self.validateEachStage = validateEachStage
        self.visualPaceMs = visualPaceMs
        self.headlessViewport = headlessViewport
        self.maxStageRecoveries = maxStageRecoveries
        self.betweenStagesDelayMs = betweenStagesDelayMs
    }

    public static let `default` = BrowserAgentConfiguration()
}

// MARK: - BrowserAgent

@MainActor
public final class BrowserAgent: ObservableObject {

    // ---- Public observable state (for SwiftUI) ----------------------------

    @Published public internal(set) var executor: BrowserToolExecutor?
    @Published public internal(set) var isAvailable: Bool = false
    @Published public internal(set) var isExecuting: Bool = false
    @Published public internal(set) var currentURL: String?
    @Published public internal(set) var currentTitle: String?
    @Published public internal(set) var lastScreenshot: Data?
    @Published public internal(set) var lastAction: String?

    /// Human-readable target of the last action (URL, selector, search query
    /// text) — populated alongside `lastAction` so SwiftUI views can render
    /// "what was clicked / where we navigated" without parsing arg dicts.
    @Published public internal(set) var lastActionTarget: String?

    /// Optional one-line explanation of why the agent took the last action
    /// (refusal nudge, validation retry, "auto-following into top story",
    /// etc.). Hidden by default, surfaced for debugging UX.
    @Published public internal(set) var lastActionReason: String?

    /// Coarse-grained activity the agent is doing RIGHT NOW. SwiftUI views
    /// should show this prominently so the user always knows the agent is
    /// alive and what step it's on.
    @Published public internal(set) var currentPhase: AgentPhase = .idle

    // ---- Internals --------------------------------------------------------

    public var configuration: BrowserAgentConfiguration

    #if canImport(UIKit)
    private var hiddenWindow: UIWindow?
    #elseif canImport(AppKit)
    private var hiddenWindow: NSWindow?
    #endif

    // ---- Public API -------------------------------------------------------

    public init(configuration: BrowserAgentConfiguration = .default) {
        self.configuration = configuration
    }

    /// Boot the underlying browser session. Idempotent.
    public func start() {
        guard executor == nil else { return }
        let exec = BrowserToolExecutor()
        if Thread.isMainThread {
            exec.start()
        } else {
            DispatchQueue.main.sync { exec.start() }
        }
        executor = exec
        isAvailable = true

        // Park the WKWebView in a hidden host with a real viewport so
        // headless `innerText` / `takeSnapshot` succeed.
        if let webView = exec.engine?.webView {
            let viewport = CGRect(origin: .zero, size: configuration.headlessViewport)
            webView.frame = viewport
            attachWebViewToHiddenHost(webView, viewport: viewport)
        }
    }

    /// Tear down the browser session and release resources.
    public func shutdown() {
        executor?.stop()
        executor = nil
        isAvailable = false
        teardownHiddenHost()
        currentURL = nil
        currentTitle = nil
        lastScreenshot = nil
        lastAction = nil
        lastActionTarget = nil
        lastActionReason = nil
        currentPhase = .idle
        isExecuting = false
    }

    /// Publish the current tool call so SwiftUI panels can render a status
    /// capsule without parsing arg dictionaries themselves. Also derives the
    /// agent's coarse `currentPhase` from the action so views always have a
    /// human-readable label of what the agent is doing right now.
    func publishAction(name: String, arguments: [String: Any], reason: String? = nil) {
        lastAction = name
        lastActionTarget = humanTarget(name: name, arguments: arguments)
        lastActionReason = reason
        currentPhase = phaseFromAction(name: name, arguments: arguments)
    }

    private func phaseFromAction(name: String, arguments: [String: Any]) -> AgentPhase {
        switch name {
        case "navigate":
            return .navigating(url: (arguments["url"] as? String) ?? "")
        case "click", "click_text":
            let target = (arguments["text"] as? String) ?? (arguments["selector"] as? String) ?? ""
            return .clicking(target: target)
        case "fill", "type":
            let field = (arguments["field"] as? String) ?? (arguments["selector"] as? String) ?? ""
            let value = (arguments["text"] as? String) ?? ""
            return .typing(field: field, value: value)
        case "scroll":
            return .scrolling(direction: (arguments["direction"] as? String) ?? "down")
        case "submit":
            return .submitting
        case "extract_text", "extract_links", "extract_forms":
            return .extracting
        case "screenshot":
            return .takingScreenshot
        case "evaluate":
            return .runningJS
        case "go_back", "go_forward", "reload":
            return .navigating(url: currentURL ?? "")
        default:
            return currentPhase
        }
    }

    private func humanTarget(name: String, arguments: [String: Any]) -> String? {
        if let url = arguments["url"] as? String, !url.isEmpty { return url }
        if let text = arguments["text"] as? String, !text.isEmpty {
            // For fill/type — show "field: value" preview.
            if name == "fill" || name == "type", let field = arguments["field"] as? String, !field.isEmpty {
                return "\(field): \(text.prefix(40))"
            }
            return String(text.prefix(60))
        }
        if let selector = arguments["selector"] as? String, !selector.isEmpty { return selector }
        if let direction = arguments["direction"] as? String, !direction.isEmpty { return direction }
        if let script = arguments["script"] as? String, !script.isEmpty {
            return String(script.prefix(40)).replacingOccurrences(of: "\n", with: " ")
        }
        return nil
    }

    /// Run the agent against a natural-language task. The AI engine is
    /// queried as needed; you observe progress via `onEvent`.
    ///
    /// - Parameters:
    ///   - task: the user's free-form instruction.
    ///   - history: prior conversation turns (so the AI has context).
    ///   - engine: AI backend that drives the agent.
    ///   - onEvent: callback for streamed events. Always called on the main
    ///     actor.
    public func run(
        task: String,
        history: [GepettoMessage] = [],
        engine: GepettoAIEngine,
        onEvent: @escaping (BrowserAgentEvent) -> Void
    ) async {
        print("🎭 [gepetto] BrowserAgent.run() ENTRY — task='\(task.prefix(120))…' history=\(history.count) maxIters=\(configuration.maxIterations)")
        currentPhase = .starting
        if executor == nil { start() }
        guard let executor = executor else {
            print("❌ [gepetto] run(): executor unavailable")
            currentPhase = .failed("session unavailable")
            onEvent(.failed(reason: "Browser session unavailable.", partialText: ""))
            return
        }

        if let script = parseAutomationScript(task) {
            print("🎭 [gepetto] run(): multi-stage script detected, \(script.count) stages")
            for (i, stage) in script.enumerated() { print("🎭 [gepetto]   stage \(i + 1): \(stage)") }
            await runScriptedFlow(
                script: script,
                executor: executor,
                engine: engine,
                userTask: task,
                history: history,
                onEvent: onEvent
            )
            return
        }

        print("🎭 [gepetto] run(): single-stage free-form path")
        await runFreeformAgent(
            task: task,
            executor: executor,
            engine: engine,
            history: history,
            onEvent: onEvent
        )
    }

    // MARK: - Multi-stage scripted flow

    private func runScriptedFlow(
        script: [AutomationStage],
        executor: BrowserToolExecutor,
        engine: GepettoAIEngine,
        userTask: String,
        history: [GepettoMessage],
        onEvent: @escaping (BrowserAgentEvent) -> Void
    ) async {
        var lastSnapshot = ""
        for (i, stage) in script.enumerated() {
            print("🎭 [gepetto] runScriptedFlow: stage \(i + 1)/\(script.count) → \(stage.url)")
            // Inter-stage cooldown so rate-limited sites don't reject the
            // sequence (HN's 1-action-per-N-seconds policy on submissions
            // is the canonical case). First stage runs immediately.
            if i > 0, configuration.betweenStagesDelayMs > 0 {
                print("🎭 [gepetto] inter-stage cooldown \(configuration.betweenStagesDelayMs)ms before stage \(i + 1)")
                try? await Task.sleep(nanoseconds: UInt64(configuration.betweenStagesDelayMs) * 1_000_000)
            }
            ensureWebViewHasLayoutContext(executor)

            publishAction(name: "navigate", arguments: ["url": stage.url])

            onEvent(.action(name: "navigate", arguments: ["url": stage.url]))
            isExecuting = true
            let nav = await executor.execute(json: ["action": "navigate", "url": stage.url])
            let success = nav.success
            isExecuting = false
            print("🎭 [gepetto]   stage \(i + 1) navigate success=\(success)")
            lastSnapshot = await postNavigateSnapshot(executor: executor, navResult: nav, fallbackURL: stage.url)
            onEvent(.actionResult(summary: lastSnapshot, success: success))

            if !success {
                onEvent(.failed(reason: "Navigation to \(stage.url) failed.", partialText: lastSnapshot))
                return
            }

            await visualPace()

            if let plan = stage.fillPlan {
                lastSnapshot = await deterministicFormFill(
                    plan: plan,
                    executor: executor,
                    onEvent: onEvent
                )
                await visualPace(extraMs: 700)
            }

            // Per-stage validation + recovery: ask the AI engine whether the
            // post-stage page reflects success. If not, ask the engine for a
            // corrective action (shorter title, dismiss error, click another
            // button, navigate elsewhere) and retry up to maxStageRecoveries
            // times before truly giving up.
            if configuration.validateEachStage {
                currentPhase = .validating
                var validation = await validateStage(
                    stageIndex: i, stage: stage, snapshot: lastSnapshot,
                    userTask: userTask, engine: engine
                )
                onEvent(.validation(stageIndex: i, success: validation.success, reason: validation.reason))

                var recoveryAttempts = 0
                while !validation.success, recoveryAttempts < configuration.maxStageRecoveries {
                    recoveryAttempts += 1
                    currentPhase = .recovering(attempt: recoveryAttempts)
                    print("🎭 [gepetto] stage \(i + 1) failed validation (attempt #\(recoveryAttempts)/\(configuration.maxStageRecoveries)) — \(validation.reason)")

                    let recovery = await askForRecovery(
                        stageIndex: i, stage: stage, snapshot: lastSnapshot,
                        userTask: userTask, validatorReason: validation.reason,
                        engine: engine
                    )
                    print("🎭 [gepetto] stage \(i + 1) recovery decision: \(recovery)")

                    switch recovery {
                    case .giveUp(let reason):
                        onEvent(.failed(
                            reason: "Stage \(i + 1) failed: \(validation.reason). Recovery declined: \(reason)",
                            partialText: lastSnapshot
                        ))
                        return
                    case .retryForm(let newValues, let summary):
                        onEvent(.recovering(stageIndex: i, attempt: recoveryAttempts, plan: summary))
                        // Re-fetch the page state (form may have re-rendered
                        // after submit) and re-fill with the new values.
                        lastSnapshot = await postNavigateSnapshot(
                            executor: executor,
                            navResult: BrowserTool.Result(success: true),
                            fallbackURL: stage.url
                        )
                        let newPlan = FormFillPlan(
                            values: newValues.map { FormFillPlan.Pair(value: $0.value, fieldHint: $0.fieldHint) },
                            shouldSubmit: stage.fillPlan?.shouldSubmit ?? true
                        )
                        lastSnapshot = await deterministicFormFill(plan: newPlan, executor: executor, onEvent: onEvent)
                        await visualPace(extraMs: 700)
                    case .clickText(let text, let summary):
                        onEvent(.recovering(stageIndex: i, attempt: recoveryAttempts, plan: summary))
                        publishAction(name: "click_text", arguments: ["text": text], reason: "recovery: \(summary)")
                        onEvent(.action(name: "click_text", arguments: ["text": text]))
                        isExecuting = true
                        let r = await executor.execute(json: ["action": "click_text", "text": text])
                        isExecuting = false
                        lastSnapshot = await postNavigateSnapshot(executor: executor, navResult: r, fallbackURL: stage.url)
                        onEvent(.actionResult(summary: lastSnapshot, success: r.success))
                        await visualPace(extraMs: 500)
                    case .navigate(let url, let summary):
                        onEvent(.recovering(stageIndex: i, attempt: recoveryAttempts, plan: summary))
                        publishAction(name: "navigate", arguments: ["url": url], reason: "recovery: \(summary)")
                        onEvent(.action(name: "navigate", arguments: ["url": url]))
                        isExecuting = true
                        let r = await executor.execute(json: ["action": "navigate", "url": url])
                        isExecuting = false
                        lastSnapshot = await postNavigateSnapshot(executor: executor, navResult: r, fallbackURL: url)
                        onEvent(.actionResult(summary: lastSnapshot, success: r.success))
                        await visualPace(extraMs: 500)
                    }

                    // Re-validate after the recovery action.
                    validation = await validateStage(
                        stageIndex: i, stage: stage, snapshot: lastSnapshot,
                        userTask: userTask, engine: engine
                    )
                    onEvent(.validation(stageIndex: i, success: validation.success, reason: validation.reason))
                }

                if !validation.success {
                    onEvent(.failed(
                        reason: "Stage \(i + 1) still failing after \(recoveryAttempts) recovery attempt(s): \(validation.reason)",
                        partialText: lastSnapshot
                    ))
                    return
                }
            }
        }

        // Final summary turn.
        await streamSummary(
            engine: engine,
            history: history,
            userTask: userTask,
            finalSnapshot: lastSnapshot,
            onEvent: onEvent
        )
    }

    /// What the AI engine decided to do when a stage validation failed.
    enum StageRecovery: CustomStringConvertible {
        case giveUp(reason: String)
        case retryForm(newValues: [(value: String, fieldHint: String)], summary: String)
        case clickText(text: String, summary: String)
        case navigate(url: String, summary: String)

        var description: String {
            switch self {
            case .giveUp(let r):           return "give-up: \(r)"
            case .retryForm(let v, let s): return "retry-form (\(v.count) field(s)): \(s)"
            case .clickText(let t, let s): return "click-text \"\(t)\": \(s)"
            case .navigate(let u, let s):  return "navigate \(u): \(s)"
            }
        }
    }

    /// Ask the AI engine for a single corrective action when a stage failed
    /// validation. The engine must respond with one line in a strict format —
    /// JSON for actionable recoveries, a `GIVE_UP:` prefix when no plausible
    /// fix exists.
    private func askForRecovery(
        stageIndex: Int,
        stage: AutomationStage,
        snapshot: String,
        userTask: String,
        validatorReason: String,
        engine: GepettoAIEngine
    ) async -> StageRecovery {
        let stageDescription = stage.fillPlan.map { plan -> String in
            let fields = plan.values.map { "\($0.fieldHint)=\"\($0.value)\"" }.joined(separator: ", ")
            return "navigate to \(stage.url) and submit form (\(fields))"
        } ?? "navigate to \(stage.url)"

        let prompt = """
        A browser automation step failed. You have ONE chance to attempt a recovery.

        ORIGINAL USER TASK:
        \(userTask)

        STAGE THAT FAILED:
        \(stageDescription)

        VALIDATOR'S REASON FOR FAILURE:
        \(validatorReason)

        CURRENT PAGE STATE:
        \(snapshot)

        Respond with EXACTLY one line, no commentary, in one of these formats:

        RETRY_FORM: {"fields":[{"hint":"<fieldHint>","value":"<new value>"}, ...]}
            Use this when one or more form values were rejected (too long, invalid format, missing) and you can supply better values. List ONLY the fields that need to change. Common fixes: shorter title, different format, fewer characters, valid email shape.

        CLICK_TEXT: {"text":"<button or link text>"}
            Use this when there's a visible button/link you should click to dismiss an error or move past a confirmation (e.g. "OK", "Dismiss", "Try Again", "Continue").

        NAVIGATE: {"url":"<destination>"}
            Use this when the recovery needs you to go to a different page entirely.

        GIVE_UP: <one-sentence reason>
            Only when there is genuinely no plausible recovery — wrong account, hard 403/404, content blocked, captcha, etc.

        Pick the SINGLE best option. Output one line.
        """

        let raw: String
        do {
            raw = try await engine.complete(messages: [GepettoMessage.user(prompt)], systemPrompt: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return .giveUp(reason: "recovery prompt failed: \(error.localizedDescription)")
        }

        // Strip leading "RETRY_FORM:" / "CLICK_TEXT:" / "NAVIGATE:" / "GIVE_UP:".
        if let body = stripped(raw, prefix: "GIVE_UP:") {
            return .giveUp(reason: body)
        }
        if let body = stripped(raw, prefix: "RETRY_FORM:"),
           let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let fields = obj["fields"] as? [[String: Any]] {
            let pairs: [(String, String)] = fields.compactMap {
                guard let hint = $0["hint"] as? String, let value = $0["value"] as? String else { return nil }
                return (value, hint)
            }
            if !pairs.isEmpty {
                let summary = pairs.map { "\($0.1)=\"\($0.0.prefix(40))…\"" }.joined(separator: ", ")
                return .retryForm(newValues: pairs.map { (value: $0.0, fieldHint: $0.1) }, summary: summary)
            }
        }
        if let body = stripped(raw, prefix: "CLICK_TEXT:"),
           let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = obj["text"] as? String, !text.isEmpty {
            return .clickText(text: text, summary: "click \"\(text)\"")
        }
        if let body = stripped(raw, prefix: "NAVIGATE:"),
           let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let url = obj["url"] as? String, !url.isEmpty {
            return .navigate(url: url, summary: "navigate to \(url)")
        }

        // Couldn't parse — log the raw output so we can iterate the prompt.
        print("⚠️ [gepetto] recovery: couldn't parse engine output, treating as give-up: \(raw.prefix(200))")
        return .giveUp(reason: "could not parse recovery output: \(raw.prefix(120))")
    }

    private func stripped(_ s: String, prefix: String) -> String? {
        guard s.uppercased().hasPrefix(prefix.uppercased()) else { return nil }
        return String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ask the AI engine to validate a stage's post-action page state.
    /// Expected response: a single line starting with `YES:` or `NO:`
    /// followed by a short reason.
    private func validateStage(
        stageIndex: Int,
        stage: AutomationStage,
        snapshot: String,
        userTask: String,
        engine: GepettoAIEngine
    ) async -> (success: Bool, reason: String) {
        let stageDescription = stage.fillPlan.map { plan -> String in
            let fields = plan.values.map { "\($0.fieldHint)=\"\($0.value)\"" }.joined(separator: ", ")
            return "navigate to \(stage.url) and submit form (\(fields))"
        } ?? "navigate to \(stage.url)"

        let validationPrompt = """
        You are validating a single step of a browser automation script.

        OVERALL TASK: \(userTask)

        THIS STEP: \(stageDescription)

        PAGE STATE AFTER THE STEP:
        \(snapshot)

        Did this step succeed? Specifically:
        - For login pages: are we logged in (no "Bad login", "incorrect password", "wrong username", etc.)?
        - For form submissions: did the form submit cleanly (no validation errors like "required", "must be filled", "invalid")?
        - For navigation: did we land on the right kind of page (not a 404 / "Page not found" / error)?

        Respond with EXACTLY one line: "YES: <one-sentence reason>" or "NO: <one-sentence reason>". No other text.
        """

        do {
            let answer = try await engine.complete(
                messages: [GepettoMessage.user(validationPrompt)],
                systemPrompt: nil
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = answer.uppercased()
            if upper.hasPrefix("YES") {
                return (true, answer.dropPrefix("YES:").trimmingCharacters(in: .whitespacesAndNewlines))
            } else if upper.hasPrefix("NO") {
                return (false, answer.dropPrefix("NO:").trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                // If we can't parse, conservatively pass — better to keep
                // going than block on a parser nit.
                return (true, "unparseable validator output: \(answer.prefix(120))")
            }
        } catch {
            // Don't block the script on validator errors.
            return (true, "validator error (continuing): \(error.localizedDescription)")
        }
    }

    private func streamSummary(
        engine: GepettoAIEngine,
        history: [GepettoMessage],
        userTask: String,
        finalSnapshot: String,
        onEvent: @escaping (BrowserAgentEvent) -> Void
    ) async {
        currentPhase = .summarizing
        let summaryPrompt = """
        I just executed a multi-step browser automation for you. Here is the FINAL page state:

        \(finalSnapshot)

        ORIGINAL USER TASK: \(userTask)

        Write a short reply (1–2 sentences) describing whether the automation succeeded based on the final page above. Plain text only — no tool_call.
        """

        var emitted = ""
        do {
            for try await chunk in engine.stream(
                messages: history + [GepettoMessage.user(summaryPrompt)],
                systemPrompt: nil
            ) {
                let visible = ToolCallDetector.extractTextWithoutToolCall(from: emitted + chunk)
                if visible.count > emitted.count {
                    let delta = String(visible.dropFirst(emitted.count))
                    onEvent(.textChunk(delta))
                    emitted = visible
                }
            }
        } catch {
            currentPhase = .failed("summary stream failed")
            onEvent(.failed(
                reason: "Summary stream failed: \(error.localizedDescription)",
                partialText: emitted
            ))
            return
        }
        currentPhase = .finished
        onEvent(.complete(finalText: emitted.isEmpty ? "Automation completed." : emitted))
    }

    // MARK: - Free-form agent loop (single-stage / open-ended tasks)

    private func runFreeformAgent(
        task: String,
        executor: BrowserToolExecutor,
        engine: GepettoAIEngine,
        history: [GepettoMessage],
        onEvent: @escaping (BrowserAgentEvent) -> Void
    ) async {
        // If the prompt has a single URL, seed-navigate first so the AI's
        // first decision is informed by real page content.
        var seedSnapshot: String? = nil
        var didAutoFollowUp = false
        let seedURL = extractFirstURL(from: task)
        if let url = seedURL {
            ensureWebViewHasLayoutContext(executor)
            publishAction(name: "navigate", arguments: ["url": url])
            onEvent(.action(name: "navigate", arguments: ["url": url]))
            isExecuting = true
            let nav = await executor.execute(json: ["action": "navigate", "url": url])
            isExecuting = false
            let snap = await postNavigateSnapshot(executor: executor, navResult: nav, fallbackURL: url)
            seedSnapshot = snap
            onEvent(.actionResult(summary: snap, success: nav.success))
            await visualPace()

            // 1a. Form-fill takeover (single page).
            if nav.success, let plan = parseFormFillIntent(task) {
                let after = await deterministicFormFill(plan: plan, executor: executor, onEvent: onEvent)
                seedSnapshot = """
                I performed the form fill you asked for and submitted. Here is the resulting page state:

                \(after)

                Now answer the user's task using the PAGE TEXT above. Plain text only — no tool_call.
                """
                didAutoFollowUp = true
            }

            // 1b. Auto-content-click for "click into the top story" etc.
            if !didAutoFollowUp, nav.success, taskWantsContentClick(task) {
                let links = parseLinks(fromSummary: snap)
                if let target = pickContentLink(from: links, currentURL: currentURL) {
                    publishAction(name: "navigate", arguments: ["url": target.href, "text": target.text])
                    onEvent(.action(name: "navigate", arguments: ["url": target.href, "text": target.text]))
                    isExecuting = true
                    let nav2 = await executor.execute(json: ["action": "navigate", "url": target.href])
                    isExecuting = false
                    let snap2 = await postNavigateSnapshot(executor: executor, navResult: nav2, fallbackURL: target.href)
                    onEvent(.actionResult(summary: snap2, success: nav2.success))
                    seedSnapshot = """
                    I navigated into "\(target.text)" for you. Here is the page:

                    \(snap2)

                    Now answer the user's task using the PAGE TEXT above. Plain text only — no tool_call.
                    """
                    didAutoFollowUp = true
                    await visualPace()
                }
            }
        }

        // Build the dialogue and run the loop.
        var dialogue = history
        var nextUserTurn = buildInitialPrompt(userTask: task, seedSnapshot: seedSnapshot)
        var emitted = ""
        var consecutiveRefusals = 0
        var latestLinks = parseLinks(fromSummary: seedSnapshot)

        for iteration in 0..<configuration.maxIterations {
            print("🎭 [gepetto] ===== iter \(iteration + 1)/\(configuration.maxIterations) =====")
            print("🎭 [gepetto] prompt preview: \(nextUserTurn.prefix(160).replacingOccurrences(of: "\n", with: " ⏎ "))…")
            var accumulated = ""
            currentPhase = .thinking
            do {
                let messages = dialogue + [GepettoMessage.user(nextUserTurn)]
                for try await chunk in engine.stream(messages: messages, systemPrompt: nil) {
                    accumulated += chunk
                    let visible = ToolCallDetector.extractTextWithoutToolCall(from: accumulated)
                    if visible.count > emitted.count {
                        let delta = String(visible.dropFirst(emitted.count))
                        if !delta.isEmpty { onEvent(.textChunk(delta)) }
                        emitted = visible
                    }
                }
            } catch {
                currentPhase = .failed("AI stream error")
                onEvent(.failed(
                    reason: "AI stream failed: \(error.localizedDescription)",
                    partialText: emitted
                ))
                return
            }

            print("🎭 [gepetto] iter \(iteration + 1) LLM output (\(accumulated.count) chars): \(accumulated.prefix(400))")

            if let toolCall = ToolCallDetector.detectToolCall(in: accumulated),
               toolCall.name.lowercased() == "browser" {
                let args = toolCall.arguments
                let actionName = (args["action"] as? String) ?? "?"
                print("🎭 [gepetto] iter \(iteration + 1) tool_call: \(actionName) args=\(args)")
                onEvent(.action(name: actionName, arguments: args))
                isExecuting = true
                let result = await executor.execute(json: args)
                isExecuting = false
                let summary: String
                if ["navigate", "click", "click_text", "go_back", "go_forward", "reload"].contains(actionName) {
                    summary = await postNavigateSnapshot(executor: executor, navResult: result, fallbackURL: args["url"] as? String)
                } else {
                    summary = compactResultSummary(result, fallbackURL: args["url"] as? String)
                }
                latestLinks = parseLinks(fromSummary: summary)
                consecutiveRefusals = 0
                onEvent(.actionResult(summary: summary, success: result.success))

                dialogue.append(GepettoMessage.user(nextUserTurn))
                dialogue.append(GepettoMessage.assistant(accumulated))
                nextUserTurn = """
                Tool result (\(actionName), success=\(result.success)):
                \(summary)

                Decide your next action. If you have everything you need to answer the user, respond with the final answer (no tool_call). Otherwise emit another <tool_call>.
                """
            } else {
                let visible = ToolCallDetector.extractTextWithoutToolCall(from: accumulated)
                if iteration < configuration.maxIterations - 1, looksLikeRefusal(visible) {
                    consecutiveRefusals += 1
                    print("🎭 [gepetto] iter \(iteration + 1) refusal #\(consecutiveRefusals) — visible: \(visible.prefix(160))")
                    onEvent(.replaceText("Working…"))
                    emitted = ""
                    dialogue.append(GepettoMessage.user(nextUserTurn))
                    dialogue.append(GepettoMessage.assistant(accumulated))

                    if consecutiveRefusals >= 2,
                       let nextLink = pickContentLink(from: latestLinks, currentURL: currentURL) {
                        publishAction(name: "navigate", arguments: ["url": nextLink.href, "text": nextLink.text])
                        onEvent(.action(name: "navigate", arguments: ["url": nextLink.href, "text": nextLink.text]))
                        isExecuting = true
                        let nav = await executor.execute(json: ["action": "navigate", "url": nextLink.href])
                        isExecuting = false
                        let summary = await postNavigateSnapshot(executor: executor, navResult: nav, fallbackURL: nextLink.href)
                        latestLinks = parseLinks(fromSummary: summary)
                        onEvent(.actionResult(summary: summary, success: nav.success))
                        consecutiveRefusals = 0
                        nextUserTurn = """
                        I navigated to "\(nextLink.text)" for you (\(nextLink.href)). Now answer the user's task using the PAGE TEXT below. NO tool_call — write the answer in plain text.

                        \(summary)
                        """
                        continue
                    }

                    nextUserTurn = """
                    Your previous reply refused or said you needed more info. Stop refusing. The PAGE TEXT and LINKS from the previous tool result are real — use them. Pick the most likely link from LINKS that matches the user's task and emit a navigate tool_call. NO commentary, just the tool_call.

                    Required format (and nothing else):
                    <tool_call>
                    {"name":"browser","arguments":{"action":"navigate","url":"<href>"}}
                    </tool_call>
                    """
                    continue
                }

                currentPhase = .finished
                onEvent(.complete(finalText: visible.isEmpty ? accumulated : visible))
                return
            }
        }

        currentPhase = .failed("hit max iterations")
        onEvent(.failed(
            reason: "Reached max iterations (\(configuration.maxIterations)).",
            partialText: emitted
        ))
    }

    // MARK: - System / initial prompts

    private var browserAgentSystemPrompt: String {
        """
        You are an autonomous browser agent driving a real WKWebView via the `browser` tool. NEVER refuse — always emit the next tool_call.

        TOOL CALL FORMAT (must be exact, single JSON block):

        <tool_call>
        {"name":"browser","arguments":{"action":"<action>","<param>":"<value>"}}
        </tool_call>

        ACTIONS:
        - navigate (url) — load a URL
        - reload, go_back, go_forward
        - extract_text — visible text of current page
        - extract_links — array of {href,text}
        - extract_forms — form fields and selectors
        - screenshot — capture viewport
        - click (selector) — CSS selector click
        - click_text (text) — click element whose text contains this
        - fill (selector, text) — set form input value
        - type (selector, text) — type into focused input
        - scroll (direction) — "down"|"up"|"top"|"bottom"
        - evaluate (script) — run JavaScript, returns string

        RULES:
        1. Issue ONE tool_call per turn. After each call you receive a "Tool result" with PAGE TEXT and LINKS.
        2. When you have enough info to answer, respond with plain-text final answer (NO tool_call). That ends the session.
        3. NEVER apologize for being a text model, NEVER claim you can't browse, NEVER ask the user to do anything.
        4. Be concise — at most one short sentence of commentary per turn.
        """
    }

    private func buildInitialPrompt(userTask: String, seedSnapshot: String?) -> String {
        let stateBlock: String
        if let snap = seedSnapshot, !snap.isEmpty {
            stateBlock = """
            Current browser state (page already loaded):
            \(snap)
            """
        } else {
            stateBlock = """
            Current browser state: no page loaded — start with a navigate tool_call.
            """
        }
        return """
        \(browserAgentSystemPrompt)

        ----

        User's task: \(userTask)

        \(stateBlock)

        Decide your next action. If the page above already contains enough info to answer, respond with the final answer (no tool_call). Otherwise emit a single <tool_call>.
        """
    }

    // MARK: - Visual pacing

    private func visualPace(extraMs: Int = 0) async {
        let total = configuration.visualPaceMs + extraMs
        guard total > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(total) * 1_000_000)
    }

    // MARK: - Headless host

    private func ensureWebViewHasLayoutContext(_ executor: BrowserToolExecutor) {
        guard let webView = executor.engine?.webView else { return }
        if webView.window == nil || webView.bounds.width < 1 || webView.bounds.height < 1 {
            let viewport = CGRect(origin: .zero, size: configuration.headlessViewport)
            webView.frame = viewport
            attachWebViewToHiddenHost(webView, viewport: viewport)
        }
    }

    #if canImport(UIKit)
    private func attachWebViewToHiddenHost(_ webView: WKWebView, viewport: CGRect) {
        let window: UIWindow
        if let existing = hiddenWindow {
            window = existing
        } else {
            window = UIWindow(frame: viewport)
            window.windowLevel = .alert + 1
            window.alpha = 0
            window.isUserInteractionEnabled = false
            window.rootViewController = UIViewController()
            window.isHidden = false
            hiddenWindow = window
        }
        guard let host = window.rootViewController?.view else { return }
        host.frame = viewport
        webView.removeFromSuperview()
        host.addSubview(webView)
    }

    private func teardownHiddenHost() {
        hiddenWindow?.isHidden = true
        hiddenWindow?.rootViewController = nil
        hiddenWindow = nil
    }
    #elseif canImport(AppKit)
    private func attachWebViewToHiddenHost(_ webView: WKWebView, viewport: CGRect) {
        let window: NSWindow
        if let existing = hiddenWindow {
            window = existing
        } else {
            window = NSWindow(
                contentRect: viewport,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.alphaValue = 0
            window.isOpaque = false
            window.ignoresMouseEvents = true
            window.contentView = NSView(frame: viewport)
            window.orderOut(nil)
            hiddenWindow = window
        }
        guard let host = window.contentView else { return }
        host.frame = viewport
        webView.removeFromSuperview()
        host.addSubview(webView)
    }

    private func teardownHiddenHost() {
        hiddenWindow?.orderOut(nil)
        hiddenWindow = nil
    }
    #else
    private func attachWebViewToHiddenHost(_ webView: WKWebView, viewport: CGRect) {}
    private func teardownHiddenHost() {}
    #endif

    // MARK: - Executor execute helpers

    /// Run the executor and update our @Published state from the result.
    @discardableResult
    fileprivate func runAction(
        executor: BrowserToolExecutor,
        json: [String: Any]
    ) async -> BrowserTool.Result {
        lastAction = json["action"] as? String
        let result = await executor.execute(json: json)
        if let url = json["url"] as? String, lastAction == "navigate" { currentURL = url }
        if let title = executor.engine?.pageTitle { currentTitle = title }
        if let screenshot = result.screenshot { lastScreenshot = screenshot }
        return result
    }
}

// MARK: - String prefix helper

private extension String {
    func dropPrefix(_ prefix: String) -> String {
        guard self.uppercased().hasPrefix(prefix.uppercased()) else { return self }
        return String(self.dropFirst(prefix.count))
    }
}

// MARK: - URL extraction

@MainActor
extension BrowserAgent {
    fileprivate func extractFirstURL(from text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        if let match = detector.firstMatch(in: text, options: [], range: range),
           let url = match.url, let scheme = url.scheme, scheme.hasPrefix("http") {
            return url.absoluteString
        }
        let pattern = #"\b([a-z0-9-]+\.)+[a-z]{2,}(\/[\w\-./?%&=#+]*)?"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           let m = regex.firstMatch(in: text, options: [], range: range),
           let r = Range(m.range, in: text) {
            return "https://" + String(text[r])
        }
        return nil
    }
}
