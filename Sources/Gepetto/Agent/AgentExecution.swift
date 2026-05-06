//
//  AgentExecution.swift
//  Gepetto
//
//  Helpers used by `BrowserAgent` to execute and summarize actions:
//  deterministic form-fill, post-navigate snapshots, link parsing, content
//  link picking. Kept in their own file to keep `BrowserAgent.swift` legible.
//

import Foundation

@MainActor
extension BrowserAgent {

    // MARK: - Deterministic form fill

    /// Drive a form deterministically with post-fill verification:
    ///   1. extract_forms → get real selectors
    ///   2. for each planned value: pick the best field, fill it, then read
    ///      back the value via JS. If the readback doesn't match, retry with
    ///      the keystroke-based `type` action which dispatches keyboard
    ///      events and works around inputs that reject scripted assignment.
    ///   3. submit the FORM that contains the fields we filled (not just
    ///      `document.querySelector('input[type=submit]')` which can pick a
    ///      submit button from the wrong form on pages with multiple forms).
    public func deterministicFormFill(
        plan: FormFillPlan,
        executor: BrowserToolExecutor,
        onEvent: @escaping (BrowserAgentEvent) -> Void
    ) async -> String {
        let formsResult = await executor.execute(json: ["action": "extract_forms"])
        let fields = formsResult.formFields ?? []

        var alreadyUsed = Set<String>()
        var firstFilledSelector: String? = nil
        for pair in plan.values {
            guard let pick = matchField(hint: pair.fieldHint, value: pair.value, fields: fields, exclude: alreadyUsed) else {
                print("⚠️ [gepetto] no field matched hint='\(pair.fieldHint)' for value='\(pair.value.prefix(8))…'")
                continue
            }
            alreadyUsed.insert(pick.selector)
            if firstFilledSelector == nil { firstFilledSelector = pick.selector }

            await fillAndVerify(
                selector: pick.selector,
                value: pair.value,
                label: pick.label,
                executor: executor,
                onEvent: onEvent
            )
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        if plan.shouldSubmit {
            try? await Task.sleep(nanoseconds: 500_000_000)
            publishAction(name: "submit", arguments: ["via": "form_scoped_submit"])
            onEvent(.action(name: "submit", arguments: ["via": "form_scoped_submit"]))
            isExecuting = true
            _ = await executor.execute(json: [
                "action": "evaluate",
                "script": formScopedSubmitScript(anchorSelector: firstFilledSelector ?? "")
            ])
            isExecuting = false
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        let snapshot = await postNavigateSnapshot(
            executor: executor,
            navResult: BrowserTool.Result(success: true),
            fallbackURL: currentURL
        )
        onEvent(.actionResult(summary: snapshot, success: true))
        return snapshot
    }

    /// Fill a field, read back its value, and retry with the keystroke-based
    /// `type` action if the readback doesn't match what we tried to set.
    /// This catches inputs that reject `el.value = X` (rare, but real on
    /// some controlled-input frameworks like React with onChange handlers).
    private func fillAndVerify(
        selector: String,
        value: String,
        label: String,
        executor: BrowserToolExecutor,
        onEvent: @escaping (BrowserAgentEvent) -> Void
    ) async {
        onEvent(.action(name: "fill", arguments: [
            "selector": selector, "text": value, "field": label
        ]))
        isExecuting = true
        _ = await executor.execute(json: [
            "action": "fill", "selector": selector, "text": value
        ])
        isExecuting = false

        // Read back the value via JS to verify the fill actually took.
        let readback = await executor.execute(json: [
            "action": "evaluate",
            "script": "(document.querySelector(\(jsString(selector)))?.value) ?? ''"
        ])
        let actual = readback.data ?? ""
        if actual == value {
            print("✅ [gepetto] fill verified: \(selector) = \(value.prefix(8))…")
            return
        }

        // Mismatch — retry with `type` (focus + per-character keystrokes).
        // First clear, then type.
        print("⚠️ [gepetto] fill verification FAILED for \(selector). expected=\(value.prefix(12)) got='\(actual.prefix(12))'. Retrying with type().")
        _ = await executor.execute(json: [
            "action": "evaluate",
            "script": "(function(){var e=document.querySelector(\(jsString(selector)));if(e){e.value='';e.focus();}return 'cleared';})();"
        ])
        try? await Task.sleep(nanoseconds: 100_000_000)
        isExecuting = true
        _ = await executor.execute(json: [
            "action": "type", "selector": selector, "text": value, "delay": 30
        ])
        isExecuting = false

        let readback2 = await executor.execute(json: [
            "action": "evaluate",
            "script": "(document.querySelector(\(jsString(selector)))?.value) ?? ''"
        ])
        let actual2 = readback2.data ?? ""
        if actual2 == value {
            print("✅ [gepetto] type() retry succeeded: \(selector)")
        } else {
            print("❌ [gepetto] still couldn't fill \(selector) after type() retry. expected=\(value.prefix(12)) got='\(actual2.prefix(12))'")
        }
    }

    /// JS that submits the FORM containing the field at `anchorSelector`,
    /// not just the first submit button on the page. Falls back gracefully
    /// when there's no anchor (e.g. an empty fill plan with shouldSubmit).
    private func formScopedSubmitScript(anchorSelector: String) -> String {
        guard !anchorSelector.isEmpty else {
            return """
            (function () {
                var btn = document.querySelector('input[type=submit], button[type=submit]');
                if (btn) { btn.click(); return 'clicked-button'; }
                var form = document.querySelector('form');
                if (form) { form.submit(); return 'form-submit'; }
                return 'no-form';
            })();
            """
        }
        return """
        (function () {
            var anchor = document.querySelector(\(jsString(anchorSelector)));
            if (!anchor) {
                var btn = document.querySelector('input[type=submit], button[type=submit]');
                if (btn) { btn.click(); return 'no-anchor-clicked-fallback-button'; }
                return 'no-anchor-no-button';
            }
            var form = anchor.form || anchor.closest('form');
            if (!form) {
                anchor.click(); return 'no-form-clicked-anchor';
            }
            // Prefer a submit button INSIDE this specific form so we trigger
            // any form-scoped onsubmit handler the page wires up.
            var btn = form.querySelector('input[type=submit], button[type=submit], button:not([type])');
            if (btn) { btn.click(); return 'clicked-form-button'; }
            form.submit();
            return 'form-submit';
        })();
        """
    }

    /// Quote a Swift string as a JS string literal, including special chars
    /// (backslashes, quotes, newlines).
    private func jsString(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:   out.append(c)
            }
        }
        out.append("\"")
        return out
    }

    /// Match a natural-language hint ("username", "password", "email",
    /// "search", "title", "url") to the most-likely real form field.
    /// Public so consumers and tests can verify which selector is picked.
    public func matchField(
        hint: String,
        value: String,
        fields: [BrowserTool.FormFieldResult],
        exclude: Set<String>
    ) -> (selector: String, label: String)? {
        let hintLower = hint.lowercased()
        let isPasswordValue = hintLower.contains("password") || hintLower.contains("pass") || hintLower.contains("pwd")
        let isUsernameHint = ["user", "name", "email", "login", "account", "acct", "id"]
            .contains(where: { hintLower.contains($0) }) && !isPasswordValue
        let isSearchHint = hintLower.contains("search") || hintLower.contains("query")
        let isTitleHint = hintLower.contains("title")
        let isURLHint = hintLower == "url" || hintLower.contains("link") || hintLower.contains("href")

        // Strict pass: type=password if hint says password.
        if isPasswordValue {
            if let f = fields.first(where: { $0.type.lowercased() == "password" && !exclude.contains($0.selector) }) {
                return (f.selector, f.name)
            }
        }

        if isUsernameHint {
            for f in fields where f.type.lowercased() != "password" {
                let blob = [f.name, f.id ?? "", f.placeholder ?? ""].joined(separator: " ").lowercased()
                if (blob.contains("user") || blob.contains("name") || blob.contains("email") ||
                    blob.contains("login") || blob.contains("acct")) && !exclude.contains(f.selector) {
                    return (f.selector, blob.isEmpty ? "username" : blob)
                }
            }
        }

        if isSearchHint {
            if let f = fields.first(where: { $0.type.lowercased() == "search" && !exclude.contains($0.selector) }) {
                return (f.selector, "search")
            }
            for f in fields {
                let blob = [f.name, f.id ?? "", f.placeholder ?? ""].joined(separator: " ").lowercased()
                if (blob.contains("search") || blob.contains("query") || blob == "q") && !exclude.contains(f.selector) {
                    return (f.selector, "search")
                }
            }
        }

        if isTitleHint {
            for f in fields {
                let blob = [f.name, f.id ?? "", f.placeholder ?? ""].joined(separator: " ").lowercased()
                if blob.contains("title") && !exclude.contains(f.selector) {
                    return (f.selector, "title")
                }
            }
        }

        if isURLHint {
            for f in fields where f.type.lowercased() != "password" {
                let blob = [f.name, f.id ?? "", f.placeholder ?? ""].joined(separator: " ").lowercased()
                if (blob.contains("url") || blob.contains("link") || blob.contains("href")) && !exclude.contains(f.selector) {
                    return (f.selector, "url")
                }
            }
        }

        // Fallback: first compatible unused field.
        for f in fields {
            let type = f.type.lowercased()
            if isPasswordValue && type != "password" { continue }
            if !isPasswordValue && type == "password" { continue }
            if !exclude.contains(f.selector) { return (f.selector, f.name) }
        }
        return nil
    }

    // MARK: - Post-action snapshot

    /// After a navigation/click, fetch text + links so the agent (and the AI
    /// validator) has the page content. Polls extract_text to handle pages
    /// that haven't fully painted yet.
    func postNavigateSnapshot(
        executor: BrowserToolExecutor,
        navResult: BrowserTool.Result,
        fallbackURL: String?
    ) async -> String {
        var lines: [String] = []
        let url = currentURL ?? fallbackURL ?? "(unknown)"
        let title = currentTitle ?? executor.engine?.pageTitle ?? "(unknown)"
        if let liveURL = executor.engine?.currentURL?.absoluteString { currentURL = liveURL }
        if let liveTitle = executor.engine?.pageTitle { currentTitle = liveTitle }
        lines.append("URL=\(currentURL ?? url)  Title=\(currentTitle ?? title)")
        if let msg = navResult.message, !msg.isEmpty { lines.append(msg) }
        if let err = navResult.error, !err.isEmpty { lines.append("Error: \(err)") }

        var pageText = ""
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
            let r = await executor.execute(json: ["action": "extract_text"])
            if let s = r.data, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pageText = s
                break
            }
        }
        if !pageText.isEmpty {
            lines.append("PAGE TEXT (truncated):\n\(truncate(collapseWhitespace(pageText), max: 1800))")
        }

        let linksResult = await executor.execute(json: ["action": "extract_links"])
        if let links = linksResult.links, !links.isEmpty {
            let preview = links.prefix(20).map { l in
                "- \(truncate(l.text, max: 80)) → \(l.href)"
            }.joined(separator: "\n")
            lines.append("LINKS (first 20 of \(links.count)):\n\(preview)")
        }

        if let screenshot = navResult.screenshot { lastScreenshot = screenshot }

        return lines.joined(separator: "\n")
    }

    /// One-action result summary (when `postNavigateSnapshot` would be
    /// overkill, e.g. for non-navigating actions like extract_text alone).
    func compactResultSummary(_ result: BrowserTool.Result, fallbackURL: String?) -> String {
        var parts: [String] = []
        let url = currentURL ?? fallbackURL ?? "(unknown)"
        let title = currentTitle ?? "(unknown)"
        parts.append("URL=\(url)  Title=\(title)")
        if let msg = result.message, !msg.isEmpty { parts.append(msg) }
        if let data = result.data, !data.isEmpty { parts.append(truncate(data, max: 1500)) }
        if let err = result.error, !err.isEmpty { parts.append("Error: \(err)") }
        if let links = result.links {
            let preview = links.prefix(15).map { "- \(truncate($0.text, max: 60)) → \($0.href)" }.joined(separator: "\n")
            parts.append("Links (first 15 of \(links.count)):\n\(preview)")
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Link parsing / picking

    func parseLinks(fromSummary summary: String?) -> [(href: String, text: String)] {
        guard let summary = summary, let range = summary.range(of: "LINKS (") else { return [] }
        let block = summary[range.lowerBound...]
        var out: [(String, String)] = []
        for line in block.split(separator: "\n") where line.hasPrefix("- ") {
            let trimmed = line.dropFirst(2)
            guard let arrow = trimmed.range(of: "→") else { continue }
            let text = trimmed[..<arrow.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let href = trimmed[arrow.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, !href.isEmpty { out.append((href, text)) }
        }
        return out
    }

    func pickContentLink(
        from links: [(href: String, text: String)],
        currentURL: String?
    ) -> (href: String, text: String)? {
        let currentHost = currentURL.flatMap { URL(string: $0)?.host?.lowercased() }
        for link in links {
            guard let url = URL(string: link.href),
                  let scheme = url.scheme?.lowercased(), scheme.hasPrefix("http"),
                  let host = url.host?.lowercased() else { continue }
            if host == currentHost { continue }
            if link.text.count < 3 { continue }
            let lower = link.text.lowercased()
            if ["login", "logout", "sign in", "sign up", "more", "comments"].contains(lower) { continue }
            return link
        }
        return links.first(where: { $0.text.count >= 3 })
    }

    // MARK: - Truncation helpers

    func truncate(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        let cut = s.index(s.startIndex, offsetBy: max)
        let head = String(s[..<cut])
        if let lastBreak = head.lastIndex(where: { $0 == " " || $0 == "\n" }) {
            return String(head[..<lastBreak]) + "…"
        }
        return head + "…"
    }

    func collapseWhitespace(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\r", with: "\n")
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        out = out.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
