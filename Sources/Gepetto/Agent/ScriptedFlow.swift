//
//  ScriptedFlow.swift
//  Gepetto
//
//  The deterministic multi-stage path: a task that names two or more URLs
//  ("log in at A, then post at B") is split into stages, each driven as
//  navigate → form fill → submit, with per-stage AI validation and recovery.
//  Unchanged from the original agent; the free-form loop in AgentLoop.swift
//  is where new work goes.
//

import Foundation

@MainActor
extension BrowserAgent {

    // MARK: - Multi-stage scripted flow

    func runScriptedFlow(
        script: [AutomationStage],
        executor: BrowserToolExecutor,
        engine: GepettoAIEngine,
        userTask: String,
        history: [GepettoMessage],
        onEvent: @escaping (BrowserAgentEvent) -> Void
    ) async {
        var lastSnapshot = ""
        for (i, stage) in script.enumerated() {
            // Inter-stage cooldown so rate-limited sites don't reject the
            // sequence (HN's 1-action-per-N-seconds policy on submissions
            // is the canonical case). First stage runs immediately.
            if i > 0, configuration.betweenStagesDelayMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(configuration.betweenStagesDelayMs) * 1_000_000)
            }
            ensureWebViewHasLayoutContext(executor)

            publishAction(name: "navigate", arguments: ["url": stage.url])

            onEvent(.action(name: "navigate", arguments: ["url": stage.url]))
            isExecuting = true
            let nav = await executor.execute(json: ["action": "navigate", "url": stage.url])
            let success = nav.success
            isExecuting = false
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
                    let recovery = await askForRecovery(
                        stageIndex: i, stage: stage, snapshot: lastSnapshot,
                        userTask: userTask, validatorReason: validation.reason,
                        engine: engine
                    )
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
}
