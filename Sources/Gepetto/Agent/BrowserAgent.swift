//
//  BrowserAgent.swift
//  Gepetto
//
//  The agent: a real WKWebView driven by a pluggable model
//  (`GepettoAIEngine`), with the person able to step in at any time.
//
//  Two ways of working:
//   - Agent loop (AgentLoop.swift): every task by default. Each step the
//     agent observes the page as a numbered list of elements, asks the
//     model for one action as JSON, runs it, and checks what changed.
//   - Scripted flow (ScriptedFlow.swift): legacy and opt-in
//     (`useScriptedFlowForMultiURLTasks`). Tasks naming several URLs run
//     as deterministic navigate → fill → submit stages with AI validation.
//
//  Control (AgentControl.swift): pause / resume / stop, take over / hand
//  back, confirm sensitive actions, answer the agent's questions. The UI in
//  Views/ binds to the published state here.
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
/// agent is doing: thinking, reading, typing, validating, etc.
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
    case waiting(seconds: Int)
    case paused
    case handedOver        // the person is driving
    case awaitingApproval
    case awaitingAnswer
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
        case .waiting(let s):             return "Waiting \(s)s…"
        case .paused:                     return "Paused"
        case .handedOver:                 return "You're in control"
        case .awaitingApproval:           return "Waiting for your OK"
        case .awaitingAnswer:             return "Waiting for your answer"
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
        case .handedOver:              return "hand control back when you're ready"
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
        case .waiting:            return "clock"
        case .paused:             return "pause.fill"
        case .handedOver:         return "hand.raised.fill"
        case .awaitingApproval:   return "checkmark.shield"
        case .awaitingAnswer:     return "questionmark.bubble"
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
    /// Action finished: `summary` is the result we'd feed back to the AI.
    case actionResult(summary: String, success: Bool)
    /// Per-stage validation outcome (only emitted when validation is on).
    case validation(stageIndex: Int, success: Bool, reason: String)
    /// The agent is attempting to recover from a stage failure by asking the
    /// AI for a corrective action (e.g. shorter title, click "OK" to dismiss
    /// an error, navigate elsewhere). Emitted before the recovery action runs.
    case recovering(stageIndex: Int, attempt: Int, plan: String)
    /// The model's reasoning for the step it is about to take, as it streams.
    case thinking(String)
    /// A step finished (also available as `BrowserAgent.steps`).
    case step(AgentStep)
    /// Control changed hands: paused, taken over, waiting for approval, …
    case control(AgentControlState)
    /// Agent finished cleanly with a final natural-language answer.
    case complete(finalText: String)
    /// Agent failed (bad output, max iterations, validation failure, etc.).
    case failed(reason: String, partialText: String)
}

// MARK: - Configuration

public struct BrowserAgentConfiguration: Sendable {
    /// Maximum number of agent-loop steps for the free-form path before
    /// bailing. (Kept as `maxIterations` for source compatibility.)
    public var maxIterations: Int

    /// When true, the agent asks the AI engine to validate the result page
    /// after each scripted stage. Costs an extra round-trip per stage but
    /// catches silent failures (e.g. login showed an error but the agent
    /// proceeded anyway).
    public var validateEachStage: Bool

    /// Pause between actions so the user can watch the live webview update.
    /// 0 = no pause.
    public var visualPaceMs: Int

    /// Hidden host viewport. Pages won't render correctly with frame .zero.
    public var headlessViewport: CGSize

    /// When a stage fails validation, the agent asks the AI engine for a
    /// corrective action and retries up to this many times before giving up.
    public var maxStageRecoveries: Int

    /// Pause inserted BEFORE every stage after the first in a multi-stage
    /// script, for sites that rate-limit back-to-back actions.
    public var betweenStagesDelayMs: Int

    /// How the page is observed each step.
    public var observation: ObservationOptions

    /// Draw numbered badges on the page for every element the model can see.
    /// Off by default: the model reads a text list, so the badges are only
    /// for people who want to see what it sees, and they clutter the page.
    public var showMarks: Bool

    /// Ring the element the agent is about to act on.
    public var highlightTargets: Bool

    /// Click "Accept" on cookie / consent banners before observing.
    public var autoDismissConsent: Bool

    /// Hand the page to the person when a login, verification code, captcha
    /// or payment form appears. Captchas are always handed over.
    public var handOverBlockers: Set<PageBlocker>

    /// Which sensitive actions need approval.
    public var sensitiveActions: SensitiveActionRules

    /// Template for the `search` action; `%@` is replaced by the escaped query.
    public var searchURLTemplate: String

    /// Colour (CSS) for in-page marks and highlights. Monochrome by default;
    /// the badges carry a white halo so they read on dark pages too.
    public var accentCSSColor: String

    /// How many recent steps the model is reminded of each turn.
    public var historyWindow: Int

    /// Add a little random time (0–600 ms) around the visual pace so steps
    /// do not land on a metronome. Sites rate-limit by rhythm as much as by
    /// volume, and the result reads more naturally while watching.
    public var naturalPacing: Bool

    /// Run tasks that name two or more URLs as the legacy scripted flow
    /// (navigate, fill, submit per stage) instead of the agent loop. Off by
    /// default: the scripted flow asks no approval for sensitive actions,
    /// hands nothing over for sign-ins or payments, and honours Stop, Pause
    /// and Take over only between its stages.
    public var useScriptedFlowForMultiURLTasks: Bool = false

    public init(
        maxIterations: Int = 25,
        validateEachStage: Bool = true,
        visualPaceMs: Int = 700,
        headlessViewport: CGSize = CGSize(width: 1024, height: 1366),
        maxStageRecoveries: Int = 2,
        betweenStagesDelayMs: Int = 2000,
        observation: ObservationOptions = .default,
        showMarks: Bool = false,
        highlightTargets: Bool = true,
        autoDismissConsent: Bool = true,
        handOverBlockers: Set<PageBlocker> = [.captcha, .twoFactor, .payment],
        sensitiveActions: SensitiveActionRules = .default,
        searchURLTemplate: String = "https://html.duckduckgo.com/html/?q=%@",
        accentCSSColor: String = "#111111",
        historyWindow: Int = 8,
        naturalPacing: Bool = true,
        useScriptedFlowForMultiURLTasks: Bool = false
    ) {
        self.maxIterations = maxIterations
        self.validateEachStage = validateEachStage
        self.visualPaceMs = visualPaceMs
        self.headlessViewport = headlessViewport
        self.maxStageRecoveries = maxStageRecoveries
        self.betweenStagesDelayMs = betweenStagesDelayMs
        self.observation = observation
        self.showMarks = showMarks
        self.highlightTargets = highlightTargets
        self.autoDismissConsent = autoDismissConsent
        self.handOverBlockers = handOverBlockers
        self.sensitiveActions = sensitiveActions
        self.searchURLTemplate = searchURLTemplate
        self.accentCSSColor = accentCSSColor
        self.historyWindow = historyWindow
        self.naturalPacing = naturalPacing
        self.useScriptedFlowForMultiURLTasks = useScriptedFlowForMultiURLTasks
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
    /// text), populated alongside `lastAction` so SwiftUI views can render
    /// "what was clicked / where we navigated" without parsing arg dicts.
    @Published public internal(set) var lastActionTarget: String?

    /// Optional one-line explanation of why the agent took the last action.
    @Published public internal(set) var lastActionReason: String?

    /// Coarse-grained activity the agent is doing RIGHT NOW.
    @Published public internal(set) var currentPhase: AgentPhase = .idle

    /// Who is driving, and what the agent is waiting on.
    @Published public internal(set) var controlState: AgentControlState = .idle

    /// The task being worked on.
    @Published public internal(set) var task: String?

    /// Every step taken so far in this run.
    @Published public internal(set) var steps: [AgentStep] = []

    /// The model's current reasoning, streamed as it thinks.
    @Published public internal(set) var currentThought: String?

    /// What the model has learned so far (its own notes).
    @Published public internal(set) var memory: String?

    /// The model's last raw reply, exactly as streamed. For logs and
    /// debugging; the parsed decision is what the agent acts on.
    @Published public internal(set) var lastModelReply: String?

    /// The page as last observed.
    @Published public internal(set) var snapshot: PageSnapshot?

    /// The element the agent is acting on right now, in web-view points,
    /// for cursor animation. Nil between actions.
    @Published public internal(set) var activeTargetFrame: CGRect?

    /// Hand-back summary from the most recent takeover, if any.
    @Published public internal(set) var lastHandBack: HandBackSummary?

    // ---- Internals --------------------------------------------------------

    public var configuration: BrowserAgentConfiguration

    #if canImport(UIKit)
    private var hiddenWindow: UIWindow?
    #elseif canImport(AppKit)
    private var hiddenWindow: NSWindow?
    #endif

    /// Resumed by the control API while the loop waits on the person.
    var userContinuation: CheckedContinuation<UserResponse, Never>?
    /// Set by `takeOver()` / `pause()` / `stop()`; consumed at the next step boundary.
    var pendingControl: PendingControl?
    var stopRequested = false
    /// The model reply being streamed, so `stop()`, `pause()` and
    /// `takeOver()` can end it at once instead of after its last token.
    var decisionTask: Task<StreamedReply, Error>?
    /// True from the moment `run()` starts until it returns, so a second run
    /// can never interleave with the first on the same web view.
    var runInProgress = false

    enum PendingControl { case pause, takeover }

    enum UserResponse {
        case resumed
        case handedBack(note: String?)
        case confirmed(Bool)
        case answered(String)
        case stopped
    }

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
        // A person only drives during a takeover.
        exec.engine?.setUserInteractionEnabled(true)
    }

    /// Tear down the browser session and release resources.
    public func shutdown() {
        stop()
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
        controlState = .idle
        isExecuting = false
        steps = []
        currentThought = nil
        memory = nil
        snapshot = nil
        activeTargetFrame = nil
        task = nil
    }

    // MARK: Control

    /// Pause before the next action. A reply the model is still writing is
    /// dropped and made again on resume; the page stays as it is.
    public func pause() {
        guard controlState == .running, pendingControl != .takeover else { return }
        pendingControl = .pause
        decisionTask?.cancel()
    }

    /// Continue after `pause()`. Also cancels a pause that has not taken
    /// effect yet.
    public func resume() {
        if controlState == .running, pendingControl == .pause { pendingControl = nil; return }
        guard controlState == .paused else { return }
        resumeUser(with: .resumed)
    }

    /// Stop the run. The agent reports `failed` with a "stopped" reason. A
    /// model reply in progress and a page load the run is waiting on are cut
    /// short, so the run ends within moments.
    public func stop() {
        guard controlState.isActive else { return }
        stopRequested = true
        decisionTask?.cancel()
        executor?.engine?.cancelNavigation()
        if userContinuation != nil {
            resumeUser(with: .stopped)
        } else {
            setControl(.stopping)
        }
    }

    /// Give the page to the person. Takes effect before the next action (a
    /// reply the model is still writing is dropped), or immediately when the
    /// agent is paused or waiting.
    public func takeOver() {
        switch controlState {
        case .running:
            pendingControl = .takeover
            decisionTask?.cancel()
        case .paused:
            // Swap the wait: the loop resumes and immediately enters takeover.
            pendingControl = .takeover
            resumeUser(with: .resumed)
        case .waitingForUser(.confirm), .waitingForUser(.question):
            pendingControl = .takeover
            resumeUser(with: .confirmed(false))
        default:
            break
        }
    }

    /// Return control to the agent after a takeover. `note` is shown to the
    /// model ("I logged in, use my account").
    public func handBack(note: String? = nil) {
        guard controlState.isHumanDriving else { return }
        resumeUser(with: .handedBack(note: note))
    }

    /// Approve or decline a sensitive action the agent asked about.
    public func respond(allow: Bool) {
        guard case .waitingForUser(.confirm) = controlState else { return }
        resumeUser(with: .confirmed(allow))
    }

    /// Answer a question the agent asked.
    public func answer(_ text: String) {
        guard case .waitingForUser(.question) = controlState else { return }
        resumeUser(with: .answered(text))
    }

    func setControl(_ state: AgentControlState) {
        controlState = state
        switch state {
        case .paused:              currentPhase = .paused
        case .waitingForUser(.takeover): currentPhase = .handedOver
        case .waitingForUser(.confirm):  currentPhase = .awaitingApproval
        case .waitingForUser(.question): currentPhase = .awaitingAnswer
        default: break
        }
        onControlChange?(state)
    }

    /// Set by the running loop so control changes reach its event callback.
    var onControlChange: ((AgentControlState) -> Void)?

    /// Park the loop until the person responds. Overlays are cleared first,
    /// while the agent still owns the page, and a Stop that arrived in the
    /// meantime is honoured instead of parking.
    func waitForUser(_ request: UserRequest) async -> UserResponse {
        if case .takeover = request {
            await executor?.engine?.hideMarks()
            await executor?.engine?.clearHighlight()
            activeTargetFrame = nil
        }
        if stopRequested { return .stopped }
        let response = await park(in: .waitingForUser(request))
        if case .stopped = response { return response }
        if controlState.isActive { setControl(.running) }
        return response
    }

    /// Store the continuation, then publish `state`, with no suspension in
    /// between: a Stop or Hand back tapped the moment the card appears, or a
    /// response sent from the `.control` callback itself, always reaches the
    /// loop.
    func park(in state: AgentControlState) async -> UserResponse {
        await withCheckedContinuation { (c: CheckedContinuation<UserResponse, Never>) in
            userContinuation = c
            setControl(state)
        }
    }

    private func resumeUser(with response: UserResponse) {
        guard let c = userContinuation else { return }
        userContinuation = nil
        c.resume(returning: response)
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
        // One run at a time: a second loop on the same web view would
        // interleave actions and orphan the first run's waits.
        guard !runInProgress, !controlState.isActive else {
            onEvent(.failed(reason: "A task is already running.", partialText: ""))
            return
        }
        runInProgress = true
        defer { runInProgress = false }
        currentPhase = .starting
        if executor == nil { start() }
        guard let executor = executor else {
            currentPhase = .failed("session unavailable")
            onEvent(.failed(reason: "Browser session unavailable.", partialText: ""))
            return
        }

        // Fresh run state.
        self.task = task
        steps = []
        currentThought = nil
        memory = nil
        lastHandBack = nil
        stopRequested = false
        pendingControl = nil
        onControlChange = { state in onEvent(.control(state)) }
        setControl(.running)
        executor.engine?.setUserInteractionEnabled(false)
        defer {
            executor.engine?.setUserInteractionEnabled(true)
            onControlChange = nil
            activeTargetFrame = nil
            Task { await executor.engine?.hideMarks(); await executor.engine?.clearHighlight() }
        }

        if configuration.useScriptedFlowForMultiURLTasks, let script = parseAutomationScript(task) {
            await runScriptedFlow(
                script: script,
                executor: executor,
                engine: engine,
                userTask: task,
                history: history,
                onEvent: onEvent
            )
            if case .finished = controlState {} else {
                setControl(.finished(success: currentPhase == .finished))
            }
            return
        }
        await runAgentLoop(
            task: task,
            executor: executor,
            engine: engine,
            history: history,
            onEvent: onEvent
        )
    }

    // MARK: - Visual pacing

    func visualPace(extraMs: Int = 0) async {
        var total = configuration.visualPaceMs + extraMs
        if configuration.naturalPacing { total += Int.random(in: 0...600) }
        await sleepUnlessStopped(ms: total)
    }

    /// Sleep in short slices so a Stop lands within a tenth of a second.
    func sleepUnlessStopped(ms: Int) async {
        var remaining = ms
        while remaining > 0, !stopRequested {
            let slice = min(remaining, 100)
            try? await Task.sleep(nanoseconds: UInt64(slice) * 1_000_000)
            remaining -= slice
        }
    }

    // MARK: - Headless host

    func ensureWebViewHasLayoutContext(_ executor: BrowserToolExecutor) {
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
    func runAction(
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

extension String {
    func dropPrefix(_ prefix: String) -> String {
        guard self.uppercased().hasPrefix(prefix.uppercased()) else { return self }
        return String(self.dropFirst(prefix.count))
    }
}

// MARK: - URL extraction

@MainActor
extension BrowserAgent {
    func extractFirstURL(from text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        if let match = detector.firstMatch(in: text, options: [], range: range),
           let url = match.url, let scheme = url.scheme, scheme.hasPrefix("http") {
            return BrowserAgent.preferringHTTPS(url.absoluteString, in: text)
        }
        let pattern = #"\b([a-z0-9-]+\.)+[a-z]{2,}(\/[\w\-./?%&=#+]*)?"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           let m = regex.firstMatch(in: text, options: [], range: range),
           let r = Range(m.range, in: text) {
            return "https://" + String(text[r])
        }
        return nil
    }

    /// The data detector reads a bare host ("go to demoblaze.com") as
    /// http://, which App Transport Security refuses. Use https:// unless
    /// the text itself spells out the http:// address.
    nonisolated static func preferringHTTPS(_ url: String, in text: String) -> String {
        guard url.lowercased().hasPrefix("http://"), !text.lowercased().contains(url.lowercased()) else { return url }
        return "https://" + url.dropFirst("http://".count)
    }
}
