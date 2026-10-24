//
//  PageObserver.swift
//  Gepetto
//
//  The Swift side of page observation: injects `PageScript`, takes
//  snapshots, waits for the page to settle, drives elements by index, and
//  toggles the in-page overlays. Everything here is an extension of
//  `BrowserEngine`, so any engine (headless or on screen) can be observed.
//

import Foundation
import WebKit

public struct ObservationOptions: Sendable, Equatable {
    /// Only list elements and text inside the viewport (plus a margin).
    /// Off-screen content is reachable by scrolling, exactly like a person
    /// would, and keeps the observation short enough for small models.
    public var viewportOnly: Bool = true
    public var maxElements: Int = 60
    public var maxTextChars: Int = 1500
    public var includeText: Bool = true
    public init() {}
    public static let `default` = ObservationOptions()
    public static var fullPage: ObservationOptions {
        var o = ObservationOptions(); o.viewportOnly = false; o.maxElements = 120; o.maxTextChars = 6000; return o
    }
}

/// Hard stops the agent cannot work through on its own.
public enum PageBlocker: String, Sendable, CaseIterable {
    case captcha
    case login
    case twoFactor = "two_factor"
    case payment

    public var title: String {
        switch self {
        case .captcha:   return "Verification needed"
        case .login:     return "Sign-in needed"
        case .twoFactor: return "Verification code needed"
        case .payment:   return "Payment details needed"
        }
    }

    public var message: String {
        switch self {
        case .captcha:   return "This page wants to check you are human. Take over, complete it, then hand control back."
        case .login:     return "This page asks you to sign in. Take over, log in, then hand control back."
        case .twoFactor: return "This page asks for a verification code. Enter it, then hand control back."
        case .payment:   return "This page asks for payment details. Enter them yourself, then hand control back."
        }
    }
}

@MainActor
extension BrowserEngine {

    // MARK: - Script injection

    /// The private JavaScript world `PageScript` lives in. Page scripts share
    /// the DOM with it but not its globals, so they can neither pre-empt nor
    /// rewrite `window.__gepetto`, and what the agent reads (URL, elements,
    /// blockers) comes from our code, not the page's.
    static let contentWorld = WKContentWorld.world(name: "gepetto")

    /// The user script that installs `window.__gepetto` in every frame, in
    /// `contentWorld`.
    static var pageUserScript: WKUserScript {
        WKUserScript(source: PageScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: contentWorld)
    }

    /// Run `script` in the main frame inside `contentWorld`. JavaScript null
    /// comes back as nil. (The page-world `evaluateJavaScript(_:)` stays for
    /// everything that is not page observation.)
    private func evaluateInContentWorld(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.evaluateJavaScript(script, in: nil, in: BrowserEngine.contentWorld) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value is NSNull ? nil : value)
                case .failure(let error):
                    continuation.resume(throwing: BrowserError.javaScriptError(error.localizedDescription))
                }
            }
        }
    }

    /// Make sure the script is present (pages loaded before injection, or
    /// documents that replaced themselves, may lack it). Checked and
    /// installed in `contentWorld`, where every call looks for it.
    func ensurePageScript() async {
        let present = (try? await evaluateInContentWorld("typeof window.\(PageScript.namespace) === 'object'")) as? Bool ?? false
        if !present {
            // The trailing `true` gives the install a value: it never ends
            // on `undefined`.
            _ = try? await evaluateInContentWorld(PageScript.source + "\ntrue;")
        }
    }

    private func call(_ function: String, _ args: [Any] = []) async throws -> Any? {
        await ensurePageScript()
        let encoded = try args.map { arg -> String in
            let data = try JSONSerialization.data(withJSONObject: [arg], options: [.fragmentsAllowed])
            let s = String(data: data, encoding: .utf8) ?? "[null]"
            return String(s.dropFirst().dropLast()) // strip the wrapping [ ]
        }
        // Void functions (clearHighlight) would end on `undefined`; hand back
        // null instead, which reads as nil.
        let invocation = "window.\(PageScript.namespace).\(function)(\(encoded.joined(separator: ",")))"
        return try await evaluateInContentWorld("(function () { var r = \(invocation); return r === undefined ? null : r; })()")
    }

    // MARK: - Observation

    /// Capture the page as the model will see it.
    public func observe(_ options: ObservationOptions = .default) async -> PageSnapshot {
        let dict: [String: Any] = [
            "viewportOnly": options.viewportOnly,
            "maxElements": options.maxElements,
            "textMax": options.maxTextChars,
            "includeText": options.includeText
        ]
        let raw = try? await call("snapshot", [dict])
        if let snap = PageSnapshot.from(json: raw) { return snap }
        return PageSnapshot(url: currentURL?.absoluteString ?? "", title: pageTitle ?? "", elements: [])
    }

    /// Wait until the document is loaded and the DOM has been quiet for
    /// `quietMs`, or until `timeout` passes. Returns true when settled.
    @discardableResult
    public func waitForSettle(quietMs: Int = 350, timeout: TimeInterval = 6) async -> Bool {
        let start = Date()
        // Give a just-started navigation a moment to flip isLoading.
        try? await Task.sleep(nanoseconds: 60_000_000)
        while Date().timeIntervalSince(start) < timeout {
            if !isLoading {
                let settled = (try? await call("isSettled", [quietMs])) as? Bool ?? false
                if settled { return true }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Things on this page the agent should hand to a person.
    public func blockers() async -> [PageBlocker] {
        let raw = (try? await call("blockers")) as? [String] ?? []
        return raw.compactMap(PageBlocker.init(rawValue:))
    }

    /// Click the first consent / cookie-banner button it can find.
    /// Returns the button's label when something was dismissed.
    @discardableResult
    public func dismissConsentBanner() async -> String? {
        guard let r = (try? await call("dismissConsent")) as? [String: Any],
              r["dismissed"] as? Bool == true else { return nil }
        return r["clicked"] as? String ?? "consent button"
    }

    // MARK: - Element actions by index

    public struct ElementActionResult: Sendable {
        public let ok: Bool
        public let detail: String
        public let error: String?
    }

    private func actionResult(_ raw: Any?, detailKeys: [String]) -> ElementActionResult {
        guard let r = raw as? [String: Any] else { return ElementActionResult(ok: false, detail: "", error: "no result from page") }
        let ok = r["ok"] as? Bool ?? false
        let detail = detailKeys.compactMap { r[$0] as? String }.joined(separator: " ")
        var err = r["error"] as? String
        if !ok, let options = r["options"] as? [String] { err = (err ?? "") + " options: " + options.joined(separator: " | ") }
        return ElementActionResult(ok: ok, detail: detail, error: ok ? nil : (err ?? "failed"))
    }

    public func clickElement(index: Int) async -> ElementActionResult {
        isExecutingAction = true; defer { isExecutingAction = false }
        return actionResult(try? await call("click", [index]), detailKeys: ["text"])
    }

    public func typeInto(index: Int, text: String, submit: Bool) async -> ElementActionResult {
        isExecutingAction = true; defer { isExecutingAction = false }
        return actionResult(try? await call("type", [index, text, submit]), detailKeys: ["label"])
    }

    public func selectOption(index: Int, value: String) async -> ElementActionResult {
        isExecutingAction = true; defer { isExecutingAction = false }
        return actionResult(try? await call("select", [index, value]), detailKeys: ["selected"])
    }

    public func setChecked(index: Int, checked: Bool) async -> ElementActionResult {
        isExecutingAction = true; defer { isExecutingAction = false }
        return actionResult(try? await call("setChecked", [index, checked]), detailKeys: ["state"])
    }

    public func pressKey(_ key: String) async -> ElementActionResult {
        isExecutingAction = true; defer { isExecutingAction = false }
        return actionResult(try? await call("pressKey", [key]), detailKeys: ["target"])
    }

    /// Scroll by a signed number of pixels; the page tells us whether it hit
    /// the top or bottom so the agent can stop scrolling into nothing.
    public func scrollPage(by dy: Int) async -> (atTop: Bool, atBottom: Bool) {
        let r = (try? await call("scrollBy", [dy])) as? [String: Any] ?? [:]
        return (r["atTop"] as? Bool ?? false, r["atBottom"] as? Bool ?? false)
    }

    public func scrollElementIntoView(index: Int) async {
        _ = try? await call("scrollIntoView", [index])
    }

    /// Viewport-relative frame of an element, in CSS pixels.
    public func frame(ofIndex index: Int) async -> CGRect? {
        guard let r = (try? await call("rect", [index])) as? [String: Any] else { return nil }
        func n(_ k: String) -> CGFloat { CGFloat((r[k] as? NSNumber)?.doubleValue ?? 0) }
        return CGRect(x: n("x"), y: n("y"), width: n("w"), height: n("h"))
    }

    /// CSS pixels → points in the web view: pages that are zoomed out to fit
    /// (desktop layouts on a phone) report a wider `innerWidth` than the view.
    public func cssScale() async -> CGFloat {
        // In the private world: a page can shadow window.innerWidth in its own.
        let inner = (try? await evaluateInContentWorld("window.innerWidth")) as? Double ?? 0
        guard inner > 0, webView.bounds.width > 0 else { return 1 }
        return webView.bounds.width / CGFloat(inner)
    }

    // MARK: - Overlays

    /// Draw numbered badges on every element in the last snapshot.
    public func showMarks(accent: String = "#111111") async {
        _ = try? await call("showMarks", [accent])
    }

    public func hideMarks() async {
        _ = try? await call("hideMarks")
    }

    /// Ring the element the agent is about to act on.
    public func highlight(index: Int, accent: String = "#111111", label: String? = nil) async {
        _ = try? await call("highlight", [index, accent, label ?? ""])
    }

    public func clearHighlight() async {
        _ = try? await call("clearHighlight")
    }
}
