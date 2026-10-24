//
//  AgentLoop.swift
//  Gepetto
//
//  The observe → decide → act loop for free-form tasks.
//
//  Each step:
//   1. Wait for the page to settle, dismiss a consent banner if one is up.
//   2. Observe: numbered interactive elements + visible text (PageSnapshot).
//   3. Hand over to the person if the page needs them (captcha, code, …).
//   4. Ask the model for ONE action as JSON, with its own short history and
//      memory so it never has to re-read a long transcript.
//   5. Gate the action (sensitive-action rules, loop detection), run it,
//      and tell the model what changed.
//
//  Small models get a lot of help here: one compact prompt per step, no
//  growing dialogue, explicit feedback when an action changed nothing, and
//  a forgiving parser. See AgentAction.swift for the output format.
//

import Foundation

@MainActor
extension BrowserAgent {

    // MARK: - Loop

    func runAgentLoop(
        task: String,
        executor: BrowserToolExecutor,
        engine: GepettoAIEngine,
        history: [GepettoMessage],
        onEvent: @escaping (BrowserAgentEvent) -> Void
    ) async {
        guard let browser = executor.engine else {
            finish(onEvent: onEvent, failure: "Browser session unavailable.")
            return
        }
        ensureWebViewHasLayoutContext(executor)

        var notes: [String] = []          // feedback for the next prompt
        var lastDigest: String? = nil
        var lastAction: AgentAction? = nil
        var repeats = 0
        var parseFailures = 0
        var stepsWithoutChange = 0
        var emittedThought = ""
        var previousRefs: Set<String>? = nil
        var warnedBudget = false

        // A task that names a URL starts there: the first decision is then
        // based on a real page instead of a blank one.
        if let url = extractFirstURL(from: task), !url.isEmpty {
            let step = beginStep(.navigate(url: url), thought: nil, snapshot: nil)
            let outcome = await perform(.navigate(url: url), browser: browser, snapshot: nil)
            await endStep(step, outcome: outcome, browser: browser, onEvent: onEvent)
            await visualPace()
        } else if currentURL == nil {
            notes.append("No page is open yet. Start with navigate or search.")
        }

        for stepNumber in 1...max(1, configuration.maxIterations) {
            // ---- Control: pause / takeover / stop ---------------------------
            if await handlePendingControl(browser: browser, notes: &notes, onEvent: onEvent) == .stopped {
                finish(onEvent: onEvent, failure: "Stopped by the user.")
                return
            }

            // ---- Observe --------------------------------------------------
            currentPhase = .readingPage
            await browser.waitForSettle()
            if configuration.autoDismissConsent, let dismissed = await browser.dismissConsentBanner() {
                notes.append("A cookie banner was dismissed (\"\(dismissed)\").")
                await browser.waitForSettle(quietMs: 250, timeout: 2)
            }
            var snap = await browser.observe(configuration.observation)
            snapshot = snap
            currentURL = snap.url.isEmpty ? currentURL : snap.url
            currentTitle = snap.title.isEmpty ? currentTitle : snap.title
            if configuration.showMarks { await browser.showMarks(accent: configuration.accentCSSColor) }

            // ---- Blockers: things a person must do ------------------------
            let blockers = await browser.blockers()
            if let blocker = blockers.first(where: { $0 == .captcha || configuration.handOverBlockers.contains($0) }) {
                let response = await handOver(reason: .blocker(blocker), browser: browser, onEvent: onEvent)
                if case .stopped = response { finish(onEvent: onEvent, failure: "Stopped by the user."); return }
                if let summary = lastHandBack { notes.append(summary.modelText) }
                continue
            }

            // ---- Decide ---------------------------------------------------
            currentPhase = .thinking
            currentThought = nil
            emittedThought = ""
            let budget = configuration.maxIterations
            if !warnedBudget, stepNumber >= Int(Double(budget) * 0.75) {
                warnedBudget = true
                notes.append("You have \(budget - stepNumber + 1) steps left. Finish with done soon, even if partial; say what is still missing.")
            }
            let prompt = stepPrompt(task: task, snapshot: snap, notes: notes, history: history, previousRefs: previousRefs)
            notes.removeAll()
            previousRefs = Set(snap.elements.map(\.ref))

            var raw = ""
            do {
                for try await chunk in engine.stream(messages: [GepettoMessage.user(prompt)], systemPrompt: nil) {
                    raw += chunk
                    if let partial = AgentOutputParser.partialThought(in: raw), partial != emittedThought {
                        emittedThought = partial
                        currentThought = partial
                        onEvent(.thinking(partial))
                    }
                    if stopRequested { break }
                }
            } catch {
                finish(onEvent: onEvent, failure: "AI stream failed: \(error.localizedDescription)")
                return
            }
            if stopRequested { finish(onEvent: onEvent, failure: "Stopped by the user."); return }
            lastModelReply = raw

            let decision: AgentDecision
            switch AgentOutputParser.parse(raw, allowPlainAnswer: stepNumber > 1) {
            case .success(let d):
                decision = d
                parseFailures = 0
            case .failure:
                parseFailures += 1
                if parseFailures >= 3 {
                    finish(onEvent: onEvent, failure: "The model did not return a usable action three times in a row.", partial: raw)
                    return
                }
                notes.append("Your last reply was not a valid action. Reply with ONE JSON object exactly in the format shown. Nothing else.")
                continue
            }
            if let m = decision.memory, !m.isEmpty { memory = m }
            if let t = decision.thought { currentThought = t; if t != emittedThought { onEvent(.thinking(t)) } }

            // ---- Validate the target --------------------------------------
            if let index = decision.action.targetIndex, snap.element(at: index) == nil {
                notes.append("There is no element [\(index)] on the page. Use only the indices listed under ELEMENTS, or scroll to find more.")
                continue
            }

            // ---- Loop detection -------------------------------------------
            if decision.action == lastAction {
                repeats += 1
            } else {
                repeats = 0
            }
            lastAction = decision.action
            if repeats >= 2 {
                notes.append("You have tried \(decision.action.compactDescription) three times and the page did not change. Do something different: scroll, pick another element, go back, or ask_user.")
                repeats = 0
                continue
            }

            // ---- Sensitive actions ----------------------------------------
            if let category = sensitiveCategory(of: decision.action, in: snap) {
                switch configuration.sensitiveActions.policy(for: category) {
                case .allow:
                    break
                case .block:
                    notes.append("\(decision.action.compactDescription) is a \(category.title.lowercased()) action, which this agent is not allowed to perform. Finish with done and explain what the user should do themselves.")
                    continue
                case .askFirst:
                    let summary = decision.action.humanLabel(in: snap)
                    let response = await waitForUser(.confirm(action: decision.action, summary: summary, category: category))
                    switch response {
                    case .confirmed(true):
                        break
                    case .stopped:
                        finish(onEvent: onEvent, failure: "Stopped by the user."); return
                    default:
                        if pendingControl == .takeover { continue }
                        notes.append("The user declined: \(decision.action.compactDescription). Do not retry it. Finish with done if the task cannot continue without it.")
                        continue
                    }
                }
            }

            // ---- Act ------------------------------------------------------
            let step = beginStep(decision.action, thought: decision.thought, snapshot: snap)
            if configuration.highlightTargets, let index = decision.action.targetIndex {
                await browser.highlight(index: index, accent: configuration.accentCSSColor, label: decision.action.humanLabel(in: snap))
                await pointCursor(at: index, browser: browser)
                try? await Task.sleep(nanoseconds: 350_000_000)
            }

            switch decision.action {
            case .done(let answerText, let success):
                let step = step
                await endStep(step, outcome: success ? "task complete" : "stopped", browser: browser, onEvent: onEvent)
                let text = answerText.isEmpty ? (success ? "Done." : "I could not finish this task.") : AgentOutputParser.readableAnswer(answerText)
                currentPhase = success ? .finished : .failed("gave up")
                setControl(.finished(success: success))
                onEvent(.complete(finalText: text))
                return

            case .askUser(let question):
                await endStep(step, outcome: "asked the user", browser: browser, onEvent: onEvent)
                let response = await handOver(reason: .agentAsked(question: question), browser: browser, onEvent: onEvent)
                if case .stopped = response { finish(onEvent: onEvent, failure: "Stopped by the user."); return }
                if let summary = lastHandBack { notes.append(summary.modelText) }
                continue

            default:
                let dialogBefore = browser.lastDialogMessage
                var outcome = await perform(decision.action, browser: browser, snapshot: snap)

                // ---- Receipt: what visibly changed ---------------------------
                await browser.waitForSettle()
                let after = await browser.observe(configuration.observation)
                let effect = receipt(before: snap, after: after, action: decision.action)
                if !effect.isEmpty { outcome += " Effect: \(effect)." }
                if let dialog = browser.lastDialogMessage, dialog != dialogBefore {
                    outcome += " The page showed a dialog (auto-closed): \"\(dialog.prefix(120))\"."
                }
                await endStep(step, outcome: outcome, browser: browser, onEvent: onEvent)
                snap = after
            }

            // ---- Stagnation ----------------------------------------------------
            let digest = snap.digest
            if let last = lastDigest, last == digest, decision.action.name != "wait", decision.action.name != "extract" {
                stepsWithoutChange += 1
                if stepsWithoutChange >= 4 {
                    notes.append("Nothing has changed for four steps. Finish with done (success:false) if the task is impossible, or ask_user.")
                }
            } else {
                stepsWithoutChange = 0
            }
            lastDigest = digest
            await visualPace()
            _ = stepNumber
        }

        finish(onEvent: onEvent, failure: "Reached the step limit (\(configuration.maxIterations)) without finishing.")
    }

    // MARK: - Control handling

    private enum ControlOutcome { case continued, stopped }

    /// Honour a pending pause / takeover / stop at a step boundary.
    private func handlePendingControl(browser: BrowserEngine, notes: inout [String], onEvent: @escaping (BrowserAgentEvent) -> Void) async -> ControlOutcome {
        if stopRequested { return .stopped }
        guard let pending = pendingControl else { return .continued }
        pendingControl = nil
        switch pending {
        case .pause:
            await browser.clearHighlight()
            activeTargetFrame = nil
            setControl(.paused)
            let response = await withCheckedContinuation { (c: CheckedContinuation<UserResponse, Never>) in
                userContinuation = c
            }
            if case .stopped = response { return .stopped }
            setControl(.running)
        case .takeover:
            let response = await handOver(reason: .userInitiated, browser: browser, onEvent: onEvent)
            if case .stopped = response { return .stopped }
            if let summary = lastHandBack { notes.append(summary.modelText) }
        }
        if stopRequested { return .stopped }
        // A takeover requested while paused lands here.
        if pendingControl == .takeover {
            return await handlePendingControl(browser: browser, notes: &notes, onEvent: onEvent)
        }
        return .continued
    }

    /// Give the page to the person and wait for them to hand it back.
    /// Produces `lastHandBack` describing what changed.
    func handOver(reason: TakeoverReason, browser: BrowserEngine, onEvent: @escaping (BrowserAgentEvent) -> Void) async -> UserResponse {
        let before = await browser.observe(.default)
        let blockersBefore = await browser.blockers()
        let start = Date()
        browser.setUserInteractionEnabled(true)
        let response = await waitForUser(.takeover(reason))
        browser.setUserInteractionEnabled(false)
        guard case .handedBack(let note) = response else { return response }

        await browser.waitForSettle(quietMs: 250, timeout: 3)
        let after = await browser.observe(.default)
        let blockersAfter = await browser.blockers()
        let filled = after.elements.filter { e in
            guard e.kind == "input" || e.kind == "textarea", let v = e.value, !v.isEmpty else { return false }
            let wasEmpty = before.elements.first(where: { $0.ref == e.ref })?.value?.isEmpty ?? true
            return wasEmpty
        }.map { e -> String in
            let label = e.text.isEmpty ? (e.placeholder ?? "field") : e.text
            return e.inputType == "password" ? "\(label) (hidden)" : "\(label) (\"\(e.value!.prefix(30))\")"
        }
        let summary = HandBackSummary(
            seconds: Date().timeIntervalSince(start),
            urlBefore: before.url, urlAfter: after.url, titleAfter: after.title,
            note: note, changedFields: filled,
            blockersBefore: blockersBefore, blockersAfter: blockersAfter
        )
        lastHandBack = summary
        snapshot = after
        currentURL = after.url
        currentTitle = after.title
        return response
    }

    // MARK: - Steps

    private func beginStep(_ action: AgentAction, thought: String?, snapshot: PageSnapshot?) -> AgentStep {
        let label = action.humanLabel(in: snapshot)
        var step = AgentStep(number: steps.count + 1, action: action, label: label, thought: thought)
        step.modelReply = lastModelReply
        currentPhase = phase(for: action, in: snapshot)
        lastAction = action.name
        lastActionTarget = label
        isExecuting = true
        return step
    }

    private func endStep(_ step: AgentStep, outcome: String, browser: BrowserEngine, onEvent: @escaping (BrowserAgentEvent) -> Void) async {
        var done = step
        done.outcome = outcome
        done.succeeded = !outcome.lowercased().hasPrefix("failed")
        done.duration = Date().timeIntervalSince(step.startedAt)
        done.url = browser.currentURL?.absoluteString ?? currentURL ?? ""
        steps.append(done)
        isExecuting = false
        activeTargetFrame = nil
        await browser.clearHighlight()
        onEvent(.action(name: step.action.name, arguments: arguments(for: step.action)))
        onEvent(.actionResult(summary: outcome, success: done.succeeded))
        onEvent(.step(done))
    }

    private func phase(for action: AgentAction, in snapshot: PageSnapshot?) -> AgentPhase {
        switch action {
        case .navigate(let url):            return .navigating(url: url)
        case .search(let q):                return .navigating(url: "search: \(q)")
        case .click(let i):                 return .clicking(target: snapshot?.element(at: i)?.text ?? "element \(i)")
        case .type(let i, let t, _):        return .typing(field: snapshot?.element(at: i)?.text ?? "field \(i)", value: t)
        case .select(let i, let v):         return .typing(field: snapshot?.element(at: i)?.text ?? "menu \(i)", value: v)
        case .setChecked:                   return .clicking(target: "checkbox")
        case .scroll(let d):                return .scrolling(direction: d.rawValue)
        case .scrollTo:                     return .scrolling(direction: "to element")
        case .press(let k):                 return .typing(field: "key", value: k)
        case .back:                         return .navigating(url: "back")
        case .wait(let s):                  return .waiting(seconds: Int(s.rounded()))
        case .extract:                      return .extracting
        case .askUser:                      return .awaitingAnswer
        case .done:                         return .summarizing
        }
    }

    private func arguments(for action: AgentAction) -> [String: Any] {
        switch action {
        case .navigate(let url):            return ["url": url]
        case .search(let q):                return ["text": q]
        case .click(let i):                 return ["index": i, "text": snapshot?.element(at: i)?.text ?? ""]
        case .type(let i, let t, let s):    return ["index": i, "text": t, "submit": s, "field": snapshot?.element(at: i)?.text ?? ""]
        case .select(let i, let v):         return ["index": i, "value": v]
        case .setChecked(let i, let c):     return ["index": i, "checked": c]
        case .scroll(let d):                return ["direction": d.rawValue]
        case .scrollTo(let i):              return ["index": i]
        case .press(let k):                 return ["key": k]
        case .back:                         return [:]
        case .wait(let s):                  return ["seconds": s]
        case .extract:                      return [:]
        case .askUser(let q):               return ["text": q]
        case .done(let a, let ok):          return ["text": a, "success": ok]
        }
    }

    /// Move the SwiftUI cursor to an element.
    private func pointCursor(at index: Int, browser: BrowserEngine) async {
        guard let frame = await browser.frame(ofIndex: index) else { activeTargetFrame = nil; return }
        let scale = await browser.cssScale()
        activeTargetFrame = CGRect(x: frame.minX * scale, y: frame.minY * scale,
                                   width: frame.width * scale, height: frame.height * scale)
    }

    // MARK: - Performing actions

    /// Run one action and describe the outcome in a line the model can use.
    func perform(_ action: AgentAction, browser: BrowserEngine, snapshot: PageSnapshot?) async -> String {
        let urlBefore = browser.currentURL?.absoluteString ?? ""
        func navigatedNote() -> String {
            let now = browser.currentURL?.absoluteString ?? ""
            return now != urlBefore && !now.isEmpty ? " Now at \(now)." : ""
        }

        switch action {
        case .navigate(let url):
            do {
                let result = try await browser.navigate(to: url)
                currentURL = result.url
                currentTitle = result.title
                return "loaded \(result.url)\(result.title.isEmpty ? "" : " (\(result.title))")"
            } catch {
                return "failed: \(error.localizedDescription)"
            }

        case .search(let query):
            let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            let url = configuration.searchURLTemplate.replacingOccurrences(of: "%@", with: escaped)
            do {
                let result = try await browser.navigate(to: url)
                currentURL = result.url
                currentTitle = result.title
                return "search results loaded"
            } catch {
                return "failed: \(error.localizedDescription)"
            }

        case .click(let index):
            let r = await browser.clickElement(index: index)
            guard r.ok else { return "failed: \(r.error ?? "click failed")" }
            await browser.waitForSettle()
            return "clicked \(snapshot?.element(at: index)?.humanLabel ?? "[\(index)]").\(navigatedNote())"

        case .type(let index, let text, let submit):
            let r = await browser.typeInto(index: index, text: text, submit: submit)
            guard r.ok else { return "failed: \(r.error ?? "type failed")" }
            if submit { await browser.waitForSettle() }
            return "typed into \(snapshot?.element(at: index)?.humanLabel ?? "[\(index)]")\(submit ? " and pressed Enter" : "").\(navigatedNote())"

        case .select(let index, let value):
            let r = await browser.selectOption(index: index, value: value)
            return r.ok ? "selected \(r.detail)" : "failed: \(r.error ?? "select failed")"

        case .setChecked(let index, let checked):
            let r = await browser.setChecked(index: index, checked: checked)
            return r.ok ? (checked ? "checked" : "unchecked") : "failed: \(r.error ?? "")"

        case .scroll(let direction):
            let viewport = Int(browser.webView.bounds.height * 0.8)
            let amount = max(300, viewport)
            let r: (atTop: Bool, atBottom: Bool)
            switch direction {
            case .down:   r = await browser.scrollPage(by: amount)
            case .up:     r = await browser.scrollPage(by: -amount)
            case .top:    r = await browser.scrollPage(by: -1_000_000)
            case .bottom: r = await browser.scrollPage(by: 1_000_000)
            }
            if direction == .down, r.atBottom { return "scrolled down; reached the bottom of the page" }
            if direction == .up, r.atTop { return "scrolled up; at the top of the page" }
            return "scrolled \(direction.rawValue)"

        case .scrollTo(let index):
            await browser.scrollElementIntoView(index: index)
            return "scrolled to [\(index)]"

        case .press(let key):
            let r = await browser.pressKey(key)
            await browser.waitForSettle()
            return r.ok ? "pressed \(key).\(navigatedNote())" : "failed: \(r.error ?? "")"

        case .back:
            do {
                _ = try await browser.goBack()
                return "went back.\(navigatedNote())"
            } catch {
                return "failed: \(error.localizedDescription)"
            }

        case .wait(let seconds):
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return "waited \(Int(seconds.rounded()))s"

        case .extract:
            let full = await browser.observe(.fullPage)
            let text = full.text.isEmpty ? "(no text)" : full.text
            return "FULL PAGE TEXT: \(text.prefix(4000))"

        case .askUser, .done:
            return "ok"
        }
    }

    // MARK: - Receipts

    /// One clause about what an action changed, so the model never has to
    /// guess whether a click worked: "URL changed", "12 new elements", or
    /// "nothing visible changed".
    func receipt(before: PageSnapshot, after: PageSnapshot, action: AgentAction) -> String {
        var parts: [String] = []
        if before.url != after.url { parts.append("URL changed") }
        else if before.title != after.title { parts.append("title changed to \"\(after.title.prefix(60))\"") }
        let beforeRefs = Set(before.elements.map(\.ref))
        let fresh = after.elements.filter { !beforeRefs.contains($0.ref) }.count
        let gone = before.elements.filter { b in !after.elements.contains { $0.ref == b.ref } }.count
        if fresh > 0 { parts.append("\(fresh) new element\(fresh == 1 ? "" : "s")") }
        if gone > 0, fresh == 0 { parts.append("\(gone) element\(gone == 1 ? "" : "s") gone") }
        if case .type(let i, let text, _) = action, let e = after.element(at: i) ?? after.elements.first(where: { $0.ref == before.element(at: i)?.ref }) {
            if let v = e.value, !v.isEmpty { parts.append(v == text ? "field now holds the text" : "field shows \"\(v.prefix(30))\"") }
            else if e.inputType != "password" { parts.append("field still empty") }
        }
        let lowered = after.text.lowercased()
        if lowered.range(of: #"\b(required|invalid|incorrect|try again|error|must be|not match|wrong)\b"#, options: .regularExpression) != nil,
           before.text.lowercased().range(of: #"\b(required|invalid|incorrect|try again|error|must be|not match|wrong)\b"#, options: .regularExpression) == nil {
            parts.append("a validation or error message appeared")
        }
        if parts.isEmpty, before.digest == after.digest, action.name != "wait", action.name != "extract", action.name != "scroll", action.name != "scroll_to" {
            parts.append("nothing visible changed")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Sensitive actions

    func sensitiveCategory(of action: AgentAction, in snapshot: PageSnapshot) -> SensitiveActionCategory? {
        switch action {
        case .click(let i):
            guard let e = snapshot.element(at: i), e.kind == "button" || e.kind == "link" || e.kind == "clickable" else { return nil }
            return SensitiveActionCategory.classify(label: e.text, pageText: snapshot.text)
        case .type(let i, _, let submit) where submit:
            // Submitting a form whose button is sensitive.
            guard let e = snapshot.element(at: i) else { return nil }
            let after = snapshot.elements.filter { $0.index > e.index && $0.kind == "button" }.prefix(3)
            return after.compactMap { SensitiveActionCategory.classify(label: $0.text, pageText: snapshot.text) }.first
        default:
            return nil
        }
    }

    // MARK: - Prompt

    func stepPrompt(task: String, snapshot: PageSnapshot, notes: [String], history: [GepettoMessage], previousRefs: Set<String>? = nil) -> String {
        let recent = steps.suffix(configuration.historyWindow)
        let historyBlock = recent.isEmpty ? "(none yet)" : recent.map(\.historyLine).joined(separator: "\n")
        let memoryBlock = (memory?.isEmpty == false) ? memory! : "(nothing yet)"
        let notesBlock = notes.isEmpty ? "" : "\nNOTES:\n" + notes.map { "- \($0)" }.joined(separator: "\n") + "\n"
        let context = conversationContext(history)

        return """
        You control a web browser to complete a task for the user. Each turn you see the page and reply with ONE JSON object and nothing else.
        \(context)
        TASK: \(task)

        MEMORY (your notes so far): \(memoryBlock)

        PREVIOUS STEPS:
        \(historyBlock)
        \(notesBlock)
        CURRENT PAGE:
        \(snapshot.modelDescription(maxTextChars: configuration.observation.maxTextChars, maxElements: configuration.observation.maxElements, previousRefs: previousRefs))

        ACTIONS (choose exactly one):
        {"action":"click","index":N}                           click element N
        {"action":"type","index":N,"text":"...","submit":true}  type into field N; submit:true presses Enter
        {"action":"select","index":N,"value":"..."}            choose an option in menu N
        {"action":"scroll","direction":"down"}                 down | up | top | bottom
        {"action":"navigate","url":"https://..."}              open a URL
        {"action":"search","query":"..."}                      web search
        {"action":"back"}                                      previous page
        {"action":"press","key":"Enter"}                       Enter | Escape | Tab
        {"action":"wait","seconds":2}                          let the page load
        {"action":"extract"}                                   read the whole page text
        {"action":"ask_user","question":"..."}                 you need the user: login, code, captcha, payment, a choice
        {"action":"done","answer":"...","success":true}        finished; "answer" is your reply to the user in plain sentences (never JSON or key: value pairs)

        Reply format (all four keys, one line each):
        {"evaluation":"did the last step work, in one sentence","memory":"facts to keep, one line","thought":"what to do now and why","action":{...}}

        Rules:
        - Use only the indices listed under ELEMENTS. Never invent one. If the element you need is not listed, scroll.
        - SCROLL "pages above" means content is above you: use scroll up or top to reach it; "pages below" means scroll down.
        - For search boxes use type with "submit":true.
        - Read VISIBLE TEXT before deciding; if it already answers the task, use done.
        - In done, only state facts you saw on a page. If something is missing, say so and set "success":false.
        - Write the answer the way you would say it to a person: full sentences, no JSON, no field names.
        - Never ask the user to do something you can do yourself; never apologise or explain limits.
        - One action per reply. JSON only.
        """
    }

    /// Prior conversation turns the task may refer to ("the site I mentioned").
    private func conversationContext(_ history: [GepettoMessage]) -> String {
        let turns = history.suffix(4).filter { $0.role != .system && !$0.content.isEmpty }
        guard !turns.isEmpty else { return "" }
        let lines = turns.map { "\($0.role == .user ? "User" : "Assistant"): \($0.content.prefix(240))" }
        return "\nEARLIER CONVERSATION (for context only):\n" + lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Finish

    private func finish(onEvent: @escaping (BrowserAgentEvent) -> Void, failure: String, partial: String = "") {
        currentPhase = .failed(failure)
        setControl(.finished(success: false))
        isExecuting = false
        activeTargetFrame = nil
        onEvent(.failed(reason: failure, partialText: partial))
    }
}
