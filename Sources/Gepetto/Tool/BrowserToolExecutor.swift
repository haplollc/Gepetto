//
//  BrowserToolExecutor.swift
//  Gepetto
//
//  Executes browser tool actions from LLM function calls.
//

import Foundation

/// Executes browser tool actions.
@MainActor
public final class BrowserToolExecutor: ObservableObject {
    
    /// The browser engine
    @Published public private(set) var engine: BrowserEngine?
    
    /// Whether a browser session is active
    @Published public private(set) var isActive: Bool = false
    
    /// Configuration for new browser sessions
    public let configuration: BrowserConfiguration
    
    /// Creates a new executor.
    public init(configuration: BrowserConfiguration = .default) {
        self.configuration = configuration
    }
    
    /// Start a browser session.
    public func start() {
        guard engine == nil else { return }
        engine = BrowserEngine(configuration: configuration)
        isActive = true
    }
    
    /// Stop the browser session.
    public func stop() {
        engine = nil
        isActive = false
    }
    
    /// Execute a browser tool action.
    /// - Parameter params: The action parameters
    /// - Returns: Result of the action
    public func execute(_ params: BrowserTool.Parameters) async -> BrowserTool.Result {
        // Auto-start if needed
        if engine == nil {
            start()
        }
        
        guard let engine = engine else {
            return .failure("Browser not available")
        }
        
        do {
            switch params.action {
            case .navigate:
                guard let url = params.url else {
                    return .failure("URL required for navigate action")
                }
                let result = try await engine.navigate(to: url)
                return BrowserTool.Result(
                    success: true,
                    message: "Navigated to \(result.title)",
                    data: "Title: \(result.title)\nURL: \(result.url)"
                )
                
            case .goBack:
                let result = try await engine.goBack()
                return BrowserTool.Result(
                    success: true,
                    message: "Went back to \(result.title)",
                    data: result.url
                )
                
            case .goForward:
                let result = try await engine.goForward()
                return BrowserTool.Result(
                    success: true,
                    message: "Went forward to \(result.title)",
                    data: result.url
                )
                
            case .reload:
                let result = try await engine.reload()
                return BrowserTool.Result(
                    success: true,
                    message: "Reloaded \(result.title)"
                )
                
            case .screenshot:
                let data = try await engine.screenshot(fullPage: params.fullPage ?? false)
                return BrowserTool.Result(
                    success: true,
                    message: "Screenshot captured (\(data.count) bytes)",
                    screenshot: data
                )
                
            case .extractText:
                let text = try await engine.extractText()
                return BrowserTool.Result(
                    success: true,
                    message: "Extracted \(text.count) characters",
                    data: text
                )
                
            case .extractHTML:
                let html = try await engine.extractHTML(selector: params.selector)
                return BrowserTool.Result(
                    success: true,
                    message: "Extracted HTML",
                    data: html
                )
                
            case .getTitle:
                let title = try await engine.getTitle()
                return BrowserTool.Result(
                    success: true,
                    data: title
                )
                
            case .getURL:
                let url = try await engine.getURL()
                return BrowserTool.Result(
                    success: true,
                    data: url
                )
                
            case .extractLinks:
                let links = try await engine.extractLinks()
                let linkResults = links.map { 
                    BrowserTool.LinkResult(href: $0.href, text: $0.text, title: $0.title)
                }
                return BrowserTool.Result(
                    success: true,
                    message: "Found \(links.count) links",
                    links: linkResults
                )
                
            case .extractForms:
                let fields = try await engine.extractFormFields()
                let fieldResults = fields.map {
                    BrowserTool.FormFieldResult(
                        type: $0.type,
                        name: $0.name,
                        id: $0.id.isEmpty ? nil : $0.id,
                        placeholder: $0.placeholder.isEmpty ? nil : $0.placeholder,
                        selector: $0.selector
                    )
                }
                return BrowserTool.Result(
                    success: true,
                    message: "Found \(fields.count) form fields",
                    formFields: fieldResults
                )
                
            case .click:
                guard let selector = params.selector else {
                    return .failure("Selector required for click action")
                }
                try await engine.click(selector: selector)
                return BrowserTool.Result(
                    success: true,
                    message: "Clicked \(selector)"
                )
                
            case .clickText:
                guard let text = params.text else {
                    return .failure("Text required for click_text action")
                }
                try await engine.clickText(text, tag: params.tag)
                return BrowserTool.Result(
                    success: true,
                    message: "Clicked element with text '\(text)'"
                )
                
            case .fill:
                guard let selector = params.selector else {
                    return .failure("Selector required for fill action")
                }
                guard let text = params.text else {
                    return .failure("Text required for fill action")
                }
                try await engine.fill(selector: selector, text: text)
                return BrowserTool.Result(
                    success: true,
                    message: "Filled \(selector)"
                )
                
            case .type:
                guard let selector = params.selector else {
                    return .failure("Selector required for type action")
                }
                guard let text = params.text else {
                    return .failure("Text required for type action")
                }
                try await engine.type(selector: selector, text: text, delay: params.delay ?? 50)
                return BrowserTool.Result(
                    success: true,
                    message: "Typed into \(selector)"
                )
                
            case .clear:
                guard let selector = params.selector else {
                    return .failure("Selector required for clear action")
                }
                try await engine.clear(selector: selector)
                return BrowserTool.Result(
                    success: true,
                    message: "Cleared \(selector)"
                )
                
            case .submit:
                guard let selector = params.selector else {
                    return .failure("Selector required for submit action")
                }
                try await engine.submit(selector: selector)
                return BrowserTool.Result(
                    success: true,
                    message: "Submitted form"
                )
                
            case .select:
                guard let selector = params.selector else {
                    return .failure("Selector required for select action")
                }
                guard let value = params.value ?? params.text else {
                    return .failure("Value required for select action")
                }
                try await engine.select(selector: selector, value: value)
                return BrowserTool.Result(
                    success: true,
                    message: "Selected '\(value)' in \(selector)"
                )
                
            case .setChecked:
                guard let selector = params.selector else {
                    return .failure("Selector required for set_checked action")
                }
                let checked = params.checked ?? true
                try await engine.setChecked(selector: selector, checked: checked)
                return BrowserTool.Result(
                    success: true,
                    message: checked ? "Checked \(selector)" : "Unchecked \(selector)"
                )
                
            case .scroll:
                let direction = ScrollDirection(rawValue: params.direction ?? "down") ?? .down
                try await engine.scroll(direction)
                return BrowserTool.Result(
                    success: true,
                    message: "Scrolled \(direction.rawValue)"
                )
                
            case .scrollTo:
                guard let selector = params.selector else {
                    return .failure("Selector required for scroll_to action")
                }
                try await engine.scrollTo(selector: selector)
                return BrowserTool.Result(
                    success: true,
                    message: "Scrolled to \(selector)"
                )
                
            case .scrollToTop:
                try await engine.scrollToTop()
                return BrowserTool.Result(
                    success: true,
                    message: "Scrolled to top"
                )
                
            case .scrollToBottom:
                try await engine.scrollToBottom()
                return BrowserTool.Result(
                    success: true,
                    message: "Scrolled to bottom"
                )
                
            case .waitForElement:
                guard let selector = params.selector else {
                    return .failure("Selector required for wait_for_element action")
                }
                try await engine.waitForElement(selector: selector, timeout: params.timeout ?? 10)
                return BrowserTool.Result(
                    success: true,
                    message: "Element found: \(selector)"
                )
                
            case .waitForText:
                guard let text = params.text else {
                    return .failure("Text required for wait_for_text action")
                }
                try await engine.waitForText(text, timeout: params.timeout ?? 10)
                return BrowserTool.Result(
                    success: true,
                    message: "Text found: \(text)"
                )
                
            case .waitForNavigation:
                try await engine.waitForNavigation(timeout: params.timeout ?? 30)
                return BrowserTool.Result(
                    success: true,
                    message: "Navigation complete"
                )
                
            case .evaluate:
                guard let script = params.script else {
                    return .failure("Script required for evaluate action")
                }
                let result = try await engine.evaluateJavaScript(script)
                let resultString = result.map { String(describing: $0) } ?? "undefined"
                return BrowserTool.Result(
                    success: true,
                    message: "JavaScript executed",
                    data: resultString
                )
            }
        } catch let error as BrowserError {
            return BrowserTool.Result(
                success: false,
                error: error.localizedDescription
            )
        } catch {
            return BrowserTool.Result(
                success: false,
                error: error.localizedDescription
            )
        }
    }
    
    /// Execute from raw JSON parameters.
    public func execute(json: [String: Any]) async -> BrowserTool.Result {
        guard let actionStr = json["action"] as? String,
              let action = BrowserTool.Action(rawValue: actionStr) else {
            return .failure("Invalid or missing action")
        }
        
        let params = BrowserTool.Parameters(
            action: action,
            url: json["url"] as? String,
            selector: json["selector"] as? String,
            text: json["text"] as? String,
            script: json["script"] as? String,
            direction: json["direction"] as? String,
            fullPage: json["fullPage"] as? Bool,
            value: json["value"] as? String,
            checked: json["checked"] as? Bool,
            timeout: json["timeout"] as? Double,
            tag: json["tag"] as? String,
            delay: json["delay"] as? Int
        )
        
        return await execute(params)
    }
}
