//
//  BrowserEngine.swift
//  Gepetto
//
//  Core browser automation engine using WKWebView.
//  Provides programmatic control over web browsing for AI agents.
//

import Foundation
import WebKit
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Main browser automation engine.
/// Controls a WKWebView instance and provides actions for AI agents.
@MainActor
public final class BrowserEngine: NSObject, ObservableObject {
    
    // MARK: - Published State
    
    /// Current URL being displayed
    @Published public private(set) var currentURL: URL?
    
    /// Page title
    @Published public private(set) var pageTitle: String?
    
    /// Whether a page is currently loading
    @Published public private(set) var isLoading: Bool = false
    
    /// Loading progress (0.0 to 1.0)
    @Published public private(set) var loadingProgress: Double = 0
    
    /// Whether the browser can go back
    @Published public private(set) var canGoBack: Bool = false
    
    /// Whether the browser can go forward
    @Published public private(set) var canGoForward: Bool = false
    
    /// Last error that occurred
    @Published public private(set) var lastError: BrowserError?
    
    /// Whether an action is currently executing
    @Published public private(set) var isExecutingAction: Bool = false
    
    // MARK: - Internal State
    
    /// The underlying WKWebView
    public let webView: WKWebView
    
    /// Configuration for the browser
    public let configuration: BrowserConfiguration
    
    /// Continuation for navigation completion
    private var navigationContinuation: CheckedContinuation<NavigationResult, Error>?
    
    /// Observation for loading progress
    private var progressObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    private var canGoBackObservation: NSKeyValueObservation?
    private var canGoForwardObservation: NSKeyValueObservation?
    
    // MARK: - Initialization
    
    /// Creates a new browser engine with the given configuration.
    public init(configuration: BrowserConfiguration = .default) {
        self.configuration = configuration
        
        // Configure WKWebView
        let webConfig = WKWebViewConfiguration()
        #if os(iOS)
        webConfig.allowsInlineMediaPlayback = true
        webConfig.mediaTypesRequiringUserActionForPlayback = []
        #endif
        
        // Enable JavaScript
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        webConfig.defaultWebpagePreferences = prefs
        
        // User agent
        if let customUserAgent = configuration.userAgent {
            webConfig.applicationNameForUserAgent = customUserAgent
        }
        
        self.webView = WKWebView(frame: .zero, configuration: webConfig)
        
        super.init()
        
        // Set delegates
        webView.navigationDelegate = self
        webView.uiDelegate = self
        
        // Observe properties
        setupObservations()
    }
    
    deinit {
        progressObservation?.invalidate()
        titleObservation?.invalidate()
        urlObservation?.invalidate()
        canGoBackObservation?.invalidate()
        canGoForwardObservation?.invalidate()
    }
    
    private func setupObservations() {
        progressObservation = webView.observe(\.estimatedProgress) { [weak self] webView, _ in
            Task { @MainActor in
                self?.loadingProgress = webView.estimatedProgress
            }
        }
        
        titleObservation = webView.observe(\.title) { [weak self] webView, _ in
            Task { @MainActor in
                self?.pageTitle = webView.title
            }
        }
        
        urlObservation = webView.observe(\.url) { [weak self] webView, _ in
            Task { @MainActor in
                self?.currentURL = webView.url
            }
        }
        
        canGoBackObservation = webView.observe(\.canGoBack) { [weak self] webView, _ in
            Task { @MainActor in
                self?.canGoBack = webView.canGoBack
            }
        }
        
        canGoForwardObservation = webView.observe(\.canGoForward) { [weak self] webView, _ in
            Task { @MainActor in
                self?.canGoForward = webView.canGoForward
            }
        }
    }
    
    // MARK: - Navigation Actions
    
    /// Navigate to a URL.
    /// - Parameter url: The URL to navigate to (can be string or URL)
    /// - Returns: Navigation result with page info
    @discardableResult
    public func navigate(to url: String) async throws -> NavigationResult {
        guard let parsedURL = URL(string: url) ?? URL(string: "https://\(url)") else {
            throw BrowserError.invalidURL(url)
        }
        return try await navigate(to: parsedURL)
    }
    
    /// Navigate to a URL.
    @discardableResult
    public func navigate(to url: URL) async throws -> NavigationResult {
        isExecutingAction = true
        defer { isExecutingAction = false }
        
        lastError = nil
        isLoading = true
        
        return try await withCheckedThrowingContinuation { continuation in
            self.navigationContinuation = continuation
            let request = URLRequest(url: url, timeoutInterval: configuration.navigationTimeout)
            webView.load(request)
        }
    }
    
    /// Go back in history.
    @discardableResult
    public func goBack() async throws -> NavigationResult {
        guard canGoBack else {
            throw BrowserError.navigationFailed("Cannot go back - no history")
        }
        
        isExecutingAction = true
        defer { isExecutingAction = false }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.navigationContinuation = continuation
            webView.goBack()
        }
    }
    
    /// Go forward in history.
    @discardableResult
    public func goForward() async throws -> NavigationResult {
        guard canGoForward else {
            throw BrowserError.navigationFailed("Cannot go forward - no forward history")
        }
        
        isExecutingAction = true
        defer { isExecutingAction = false }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.navigationContinuation = continuation
            webView.goForward()
        }
    }
    
    /// Reload the current page.
    @discardableResult
    public func reload() async throws -> NavigationResult {
        isExecutingAction = true
        defer { isExecutingAction = false }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.navigationContinuation = continuation
            webView.reload()
        }
    }
    
    /// Stop loading the current page.
    public func stopLoading() {
        webView.stopLoading()
        isLoading = false
    }
    
    // MARK: - Content Extraction
    
    /// Take a screenshot of the current page.
    /// - Parameter fullPage: If true, captures the entire scrollable content (iOS 16+)
    /// - Returns: Screenshot as PNG data
    public func screenshot(fullPage: Bool = false) async throws -> Data {
        isExecutingAction = true
        defer { isExecutingAction = false }
        
        let config = WKSnapshotConfiguration()
        
        if fullPage {
            // Get full content size
            let contentSize = try await evaluateJavaScript(
                "[document.body.scrollWidth, document.body.scrollHeight]"
            ) as? [Int] ?? [0, 0]
            
            if contentSize[0] > 0 && contentSize[1] > 0 {
                config.rect = CGRect(
                    x: 0, y: 0,
                    width: CGFloat(contentSize[0]),
                    height: CGFloat(contentSize[1])
                )
            }
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    continuation.resume(throwing: BrowserError.screenshotFailed(error.localizedDescription))
                    return
                }
                
                guard let image = image else {
                    continuation.resume(throwing: BrowserError.screenshotFailed("No image returned"))
                    return
                }
                
                #if os(iOS)
                guard let data = image.pngData() else {
                    continuation.resume(throwing: BrowserError.screenshotFailed("Failed to encode PNG"))
                    return
                }
                #elseif os(macOS)
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                    continuation.resume(throwing: BrowserError.screenshotFailed("Failed to encode PNG"))
                    return
                }
                #endif
                
                continuation.resume(returning: data)
            }
        }
    }
    
    /// Extract all text content from the page.
    public func extractText() async throws -> String {
        let result = try await evaluateJavaScript("document.body.innerText")
        return result as? String ?? ""
    }
    
    /// Extract HTML content from the page.
    /// - Parameter selector: Optional CSS selector. If nil, returns full document HTML.
    public func extractHTML(selector: String? = nil) async throws -> String {
        let js: String
        if let selector = selector {
            js = "document.querySelector('\(escapeJS(selector))')?.outerHTML || ''"
        } else {
            js = "document.documentElement.outerHTML"
        }
        
        let result = try await evaluateJavaScript(js)
        return result as? String ?? ""
    }
    
    /// Get the current page title.
    public func getTitle() async throws -> String {
        let result = try await evaluateJavaScript("document.title")
        return result as? String ?? ""
    }
    
    /// Get the current URL.
    public func getURL() async throws -> String {
        let result = try await evaluateJavaScript("window.location.href")
        return result as? String ?? ""
    }
    
    /// Extract links from the page.
    public func extractLinks() async throws -> [LinkInfo] {
        let js = """
        Array.from(document.querySelectorAll('a[href]')).map(a => ({
            href: a.href,
            text: a.innerText.trim(),
            title: a.title || ''
        }))
        """
        
        let result = try await evaluateJavaScript(js)
        guard let links = result as? [[String: Any]] else {
            return []
        }
        
        return links.compactMap { dict in
            guard let href = dict["href"] as? String else { return nil }
            return LinkInfo(
                href: href,
                text: dict["text"] as? String ?? "",
                title: dict["title"] as? String ?? ""
            )
        }
    }
    
    /// Extract form fields from the page.
    public func extractFormFields() async throws -> [FormFieldInfo] {
        let js = """
        Array.from(document.querySelectorAll('input, textarea, select')).map(el => ({
            type: el.type || el.tagName.toLowerCase(),
            name: el.name || '',
            id: el.id || '',
            placeholder: el.placeholder || '',
            value: el.value || '',
            selector: el.id ? '#' + el.id : (el.name ? '[name="' + el.name + '"]' : null)
        })).filter(f => f.selector)
        """
        
        let result = try await evaluateJavaScript(js)
        guard let fields = result as? [[String: Any]] else {
            return []
        }
        
        return fields.compactMap { dict in
            guard let selector = dict["selector"] as? String else { return nil }
            return FormFieldInfo(
                type: dict["type"] as? String ?? "text",
                name: dict["name"] as? String ?? "",
                id: dict["id"] as? String ?? "",
                placeholder: dict["placeholder"] as? String ?? "",
                value: dict["value"] as? String ?? "",
                selector: selector
            )
        }
    }
    
    // MARK: - Interaction Actions
    
    /// Click an element by CSS selector.
    /// - Parameter selector: CSS selector for the element
    public func click(selector: String) async throws {
        isExecutingAction = true
        defer { isExecutingAction = false }
        
        let js = """
        (function() {
            const el = document.querySelector('\(escapeJS(selector))');
            if (!el) return { success: false, error: 'Element not found' };
            el.click();
            return { success: true };
        })()
        """
        
        let result = try await evaluateJavaScript(js) as? [String: Any]
        
        if result?["success"] as? Bool != true {
            let error = result?["error"] as? String ?? "Click failed"
            throw BrowserError.elementNotFound(selector, error)
        }
    }
    
    /// Click an element containing specific text.
    /// - Parameters:
    ///   - text: Text to search for
    ///   - tag: Optional tag name to filter (e.g., "button", "a")
    public func clickText(_ text: String, tag: String? = nil) async throws {
        isExecutingAction = true
        defer { isExecutingAction = false }
        
        let tagFilter = tag.map { "el.tagName.toLowerCase() === '\($0.lowercased())' && " } ?? ""
        
        let js = """
        (function() {
            const elements = Array.from(document.querySelectorAll('*'));
            const target = elements.find(el => 
                \(tagFilter)el.innerText.trim().toLowerCase().includes('\(escapeJS(text.lowercased()))')
            );
            if (!target) return { success: false, error: 'No element with text found' };
            target.click();
            return { success: true };
        })()
        """
        
        let result = try await evaluateJavaScript(js) as? [String: Any]
        
        if result?["success"] as? Bool != true {
            let error = result?["error"] as? String ?? "Click failed"
            throw BrowserError.elementNotFound("text=\(text)", error)
        }
    }
    
    /// Fill a form field with text.
    /// - Parameters:
    ///   - selector: CSS selector for the input
    ///   - text: Text to fill
    public func fill(selector: String, text: String) async throws {
        isExecutingAction = true
        defer { isExecutingAction = false }
        
        let js = """
        (function() {
            const el = document.querySelector('\(escapeJS(selector))');
            if (!el) return { success: false, error: 'Element not found' };
            el.value = '\(escapeJS(text))';
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return { success: true };
        })()
        """
        
        let result = try await evaluateJavaScript(js) as? [String: Any]
        
        if result?["success"] as? Bool != true {
            let error = result?["error"] as? String ?? "Fill failed"
            throw BrowserError.elementNotFound(selector, error)
        }
    }
    
    /// Type text character by character (for inputs that need keystroke events).
    /// - Parameters:
    ///   - selector: CSS selector for the input
    ///   - text: Text to type
    ///   - delay: Delay between keystrokes in milliseconds
    public func type(selector: String, text: String, delay: Int = 50) async throws {
        isExecutingAction = true
        defer { isExecutingAction = false }
        
        // Focus the element first
        let focusJS = """
        (function() {
            const el = document.querySelector('\(escapeJS(selector))');
            if (!el) return { success: false, error: 'Element not found' };
            el.focus();
            el.value = '';
            return { success: true };
        })()
        """
        
        let focusResult = try await evaluateJavaScript(focusJS) as? [String: Any]
        if focusResult?["success"] as? Bool != true {
            throw BrowserError.elementNotFound(selector, focusResult?["error"] as? String ?? "Focus failed")
        }
        
        // Type each character
        for char in text {
            let charJS = """
            (function() {
                const el = document.querySelector('\(escapeJS(selector))');
                if (!el) return false;
                el.value += '\(escapeJS(String(char)))';
                el.dispatchEvent(new KeyboardEvent('keydown', { key: '\(escapeJS(String(char)))' }));
                el.dispatchEvent(new KeyboardEvent('keypress', { key: '\(escapeJS(String(char)))' }));
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new KeyboardEvent('keyup', { key: '\(escapeJS(String(char)))' }));
                return true;
            })()
            """
            
            _ = try await evaluateJavaScript(charJS)
            
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            }
        }
    }
    
    /// Clear a form field.
    public func clear(selector: String) async throws {
        try await fill(selector: selector, text: "")
    }
    
    /// Submit a form.
    /// - Parameter selector: CSS selector for the form or a submit button
    public func submit(selector: String) async throws {
        isExecutingAction = true
        defer { isExecutingAction = false }
        
        let js = """
        (function() {
            let el = document.querySelector('\(escapeJS(selector))');
            if (!el) return { success: false, error: 'Element not found' };
            
            // If it's a form, submit it
            if (el.tagName.toLowerCase() === 'form') {
                el.submit();
                return { success: true };
            }
            
            // If it's inside a form, submit that form
            const form = el.closest('form');
            if (form) {
                form.submit();
                return { success: true };
            }
            
            // Otherwise, click it (might be a submit button)
            el.click();
            return { success: true };
        })()
        """
        
        let result = try await evaluateJavaScript(js) as? [String: Any]
        
        if result?["success"] as? Bool != true {
            throw BrowserError.actionFailed("submit", result?["error"] as? String ?? "Submit failed")
        }
    }
    
    /// Select an option from a dropdown.
    /// - Parameters:
    ///   - selector: CSS selector for the select element
    ///   - value: Value or visible text to select
    public func select(selector: String, value: String) async throws {
        isExecutingAction = true
        defer { isExecutingAction = false }
        
        let js = """
        (function() {
            const el = document.querySelector('\(escapeJS(selector))');
            if (!el || el.tagName.toLowerCase() !== 'select') {
                return { success: false, error: 'Select element not found' };
            }
            
            // Try to find by value first
            let option = Array.from(el.options).find(o => o.value === '\(escapeJS(value))');
            
            // Then try by text
            if (!option) {
                option = Array.from(el.options).find(o => 
                    o.text.trim().toLowerCase() === '\(escapeJS(value.lowercased()))'
                );
            }
            
            if (!option) return { success: false, error: 'Option not found' };
            
            el.value = option.value;
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return { success: true };
        })()
        """
        
        let result = try await evaluateJavaScript(js) as? [String: Any]
        
        if result?["success"] as? Bool != true {
            throw BrowserError.actionFailed("select", result?["error"] as? String ?? "Select failed")
        }
    }
    
    /// Check or uncheck a checkbox.
    public func setChecked(selector: String, checked: Bool) async throws {
        isExecutingAction = true
        defer { isExecutingAction = false }
        
        let js = """
        (function() {
            const el = document.querySelector('\(escapeJS(selector))');
            if (!el) return { success: false, error: 'Element not found' };
            if (el.checked !== \(checked)) {
                el.click();
            }
            return { success: true };
        })()
        """
        
        let result = try await evaluateJavaScript(js) as? [String: Any]
        
        if result?["success"] as? Bool != true {
            throw BrowserError.actionFailed("setChecked", result?["error"] as? String ?? "Failed")
        }
    }
    
    // MARK: - Scrolling
    
    /// Scroll the page.
    /// - Parameters:
    ///   - direction: Direction to scroll
    ///   - amount: Pixels to scroll (default 500)
    public func scroll(_ direction: ScrollDirection, amount: Int = 500) async throws {
        isExecutingAction = true
        defer { isExecutingAction = false }
        
        let (x, y): (Int, Int) = switch direction {
        case .up: (0, -amount)
        case .down: (0, amount)
        case .left: (-amount, 0)
        case .right: (amount, 0)
        }
        
        _ = try await evaluateJavaScript("window.scrollBy(\(x), \(y))")
    }
    
    /// Scroll to a specific element.
    public func scrollTo(selector: String) async throws {
        isExecutingAction = true
        defer { isExecutingAction = false }
        
        let js = """
        (function() {
            const el = document.querySelector('\(escapeJS(selector))');
            if (!el) return { success: false, error: 'Element not found' };
            el.scrollIntoView({ behavior: 'smooth', block: 'center' });
            return { success: true };
        })()
        """
        
        let result = try await evaluateJavaScript(js) as? [String: Any]
        
        if result?["success"] as? Bool != true {
            throw BrowserError.elementNotFound(selector, result?["error"] as? String ?? "Scroll failed")
        }
    }
    
    /// Scroll to top of page.
    public func scrollToTop() async throws {
        _ = try await evaluateJavaScript("window.scrollTo(0, 0)")
    }
    
    /// Scroll to bottom of page.
    public func scrollToBottom() async throws {
        _ = try await evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight)")
    }
    
    // MARK: - Waiting
    
    /// Wait for an element to appear.
    /// - Parameters:
    ///   - selector: CSS selector
    ///   - timeout: Maximum time to wait in seconds
    public func waitForElement(selector: String, timeout: TimeInterval = 10) async throws {
        let start = Date()
        
        while Date().timeIntervalSince(start) < timeout {
            let js = "document.querySelector('\(escapeJS(selector))') !== null"
            let exists = try await evaluateJavaScript(js) as? Bool ?? false
            
            if exists { return }
            
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        throw BrowserError.timeout("Element not found: \(selector)")
    }
    
    /// Wait for text to appear on the page.
    public func waitForText(_ text: String, timeout: TimeInterval = 10) async throws {
        let start = Date()
        
        while Date().timeIntervalSince(start) < timeout {
            let js = "document.body.innerText.includes('\(escapeJS(text))')"
            let exists = try await evaluateJavaScript(js) as? Bool ?? false
            
            if exists { return }
            
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        throw BrowserError.timeout("Text not found: \(text)")
    }
    
    /// Wait for navigation to complete.
    public func waitForNavigation(timeout: TimeInterval = 30) async throws {
        let start = Date()
        
        while isLoading && Date().timeIntervalSince(start) < timeout {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        if isLoading {
            throw BrowserError.timeout("Navigation did not complete")
        }
    }
    
    /// Wait for network to be idle (no pending requests).
    public func waitForNetworkIdle(timeout: TimeInterval = 10) async throws {
        // Wait a bit for any pending requests to settle
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms
        try await waitForNavigation(timeout: timeout)
    }
    
    // MARK: - JavaScript Execution
    
    /// Execute JavaScript and return the result.
    @discardableResult
    public func evaluateJavaScript(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error = error {
                    continuation.resume(throwing: BrowserError.javaScriptError(error.localizedDescription))
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    /// Escape a string for safe use in JavaScript.
    private func escapeJS(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

// MARK: - WKNavigationDelegate

extension BrowserEngine: WKNavigationDelegate {
    
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        loadingProgress = 0
    }
    
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        loadingProgress = 1.0
        
        let result = NavigationResult(
            url: webView.url?.absoluteString ?? "",
            title: webView.title ?? "",
            statusCode: 200
        )
        
        navigationContinuation?.resume(returning: result)
        navigationContinuation = nil
    }
    
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        lastError = .navigationFailed(error.localizedDescription)
        
        navigationContinuation?.resume(throwing: BrowserError.navigationFailed(error.localizedDescription))
        navigationContinuation = nil
    }
    
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        lastError = .navigationFailed(error.localizedDescription)
        
        navigationContinuation?.resume(throwing: BrowserError.navigationFailed(error.localizedDescription))
        navigationContinuation = nil
    }
}

// MARK: - WKUIDelegate

extension BrowserEngine: WKUIDelegate {
    
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Handle target="_blank" links by loading in same webview
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
