//
//  BrowserTool.swift
//  BrowserKit
//
//  Tool definition for LLM function calling.
//  Provides JSON schema for AI agents to control the browser.
//

import Foundation

/// Tool definition for browser automation in LLM function calling.
public struct BrowserTool {
    
    public static let name = "browser"
    
    public static let description = """
    Control a web browser to navigate pages, extract content, fill forms, click elements, and take screenshots. 
    Use this tool to browse the web, research information, fill out forms, or capture webpage screenshots.
    """
    
    // MARK: - Action Types
    
    /// Available browser actions
    public enum Action: String, Codable, CaseIterable, Sendable {
        /// Navigate to a URL
        case navigate
        
        /// Go back in history
        case goBack = "go_back"
        
        /// Go forward in history
        case goForward = "go_forward"
        
        /// Reload the current page
        case reload
        
        /// Take a screenshot
        case screenshot
        
        /// Extract text content from the page
        case extractText = "extract_text"
        
        /// Extract HTML content
        case extractHTML = "extract_html"
        
        /// Get page title
        case getTitle = "get_title"
        
        /// Get current URL
        case getURL = "get_url"
        
        /// Extract all links from the page
        case extractLinks = "extract_links"
        
        /// Extract form fields
        case extractForms = "extract_forms"
        
        /// Click an element
        case click
        
        /// Click element containing text
        case clickText = "click_text"
        
        /// Fill a form field
        case fill
        
        /// Type text character by character
        case type
        
        /// Clear a form field
        case clear
        
        /// Submit a form
        case submit
        
        /// Select dropdown option
        case select
        
        /// Check/uncheck checkbox
        case setChecked = "set_checked"
        
        /// Scroll the page
        case scroll
        
        /// Scroll to element
        case scrollTo = "scroll_to"
        
        /// Scroll to top
        case scrollToTop = "scroll_to_top"
        
        /// Scroll to bottom
        case scrollToBottom = "scroll_to_bottom"
        
        /// Wait for element to appear
        case waitForElement = "wait_for_element"
        
        /// Wait for text to appear
        case waitForText = "wait_for_text"
        
        /// Wait for navigation to complete
        case waitForNavigation = "wait_for_navigation"
        
        /// Execute custom JavaScript
        case evaluate
    }
    
    // MARK: - Parameters
    
    /// Parameters for browser tool calls
    public struct Parameters: Codable, Sendable {
        /// The action to perform
        public let action: Action
        
        /// URL to navigate to
        public let url: String?
        
        /// CSS selector for element targeting
        public let selector: String?
        
        /// Text for fill/type actions or text to search for
        public let text: String?
        
        /// JavaScript code to execute
        public let script: String?
        
        /// Scroll direction
        public let direction: String?
        
        /// Whether to capture full page screenshot
        public let fullPage: Bool?
        
        /// Value for select/checkbox actions
        public let value: String?
        
        /// Whether checkbox should be checked
        public let checked: Bool?
        
        /// Timeout in seconds
        public let timeout: Double?
        
        /// Tag name filter for clickText
        public let tag: String?
        
        /// Delay between keystrokes for type action (ms)
        public let delay: Int?
        
        public init(
            action: Action,
            url: String? = nil,
            selector: String? = nil,
            text: String? = nil,
            script: String? = nil,
            direction: String? = nil,
            fullPage: Bool? = nil,
            value: String? = nil,
            checked: Bool? = nil,
            timeout: Double? = nil,
            tag: String? = nil,
            delay: Int? = nil
        ) {
            self.action = action
            self.url = url
            self.selector = selector
            self.text = text
            self.script = script
            self.direction = direction
            self.fullPage = fullPage
            self.value = value
            self.checked = checked
            self.timeout = timeout
            self.tag = tag
            self.delay = delay
        }
    }
    
    // MARK: - Result
    
    /// Result of a browser action
    public struct Result: Codable, Sendable {
        /// Whether the action succeeded
        public let success: Bool
        
        /// Human-readable message
        public let message: String?
        
        /// Text data (extracted text, title, URL, etc.)
        public let data: String?
        
        /// Screenshot PNG data (base64 encoded in JSON)
        public let screenshot: Data?
        
        /// Links extracted from page
        public let links: [LinkResult]?
        
        /// Form fields extracted from page
        public let formFields: [FormFieldResult]?
        
        /// Error message if failed
        public let error: String?
        
        public init(
            success: Bool,
            message: String? = nil,
            data: String? = nil,
            screenshot: Data? = nil,
            links: [LinkResult]? = nil,
            formFields: [FormFieldResult]? = nil,
            error: String? = nil
        ) {
            self.success = success
            self.message = message
            self.data = data
            self.screenshot = screenshot
            self.links = links
            self.formFields = formFields
            self.error = error
        }
        
        /// Create a success result
        public static func success(message: String? = nil, data: String? = nil) -> Result {
            Result(success: true, message: message, data: data)
        }
        
        /// Create a failure result
        public static func failure(_ error: String) -> Result {
            Result(success: false, error: error)
        }
    }
    
    /// Link result for extraction
    public struct LinkResult: Codable, Sendable {
        public let href: String
        public let text: String
        public let title: String?
        
        public init(href: String, text: String, title: String? = nil) {
            self.href = href
            self.text = text
            self.title = title
        }
    }
    
    /// Form field result for extraction
    public struct FormFieldResult: Codable, Sendable {
        public let type: String
        public let name: String
        public let id: String?
        public let placeholder: String?
        public let selector: String
        
        public init(type: String, name: String, id: String?, placeholder: String?, selector: String) {
            self.type = type
            self.name = name
            self.id = id
            self.placeholder = placeholder
            self.selector = selector
        }
    }
    
    // MARK: - JSON Schema
    
    /// JSON Schema for LLM function calling
    public static var jsonSchema: [String: Any] {
        [
            "name": name,
            "description": description,
            "parameters": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": Action.allCases.map(\.rawValue),
                        "description": "The browser action to perform"
                    ],
                    "url": [
                        "type": "string",
                        "description": "URL to navigate to (required for 'navigate' action)"
                    ],
                    "selector": [
                        "type": "string",
                        "description": "CSS selector for the target element (required for click, fill, type, scroll_to, wait_for_element actions)"
                    ],
                    "text": [
                        "type": "string",
                        "description": "Text to fill/type into element, or text to search for (click_text, wait_for_text)"
                    ],
                    "script": [
                        "type": "string",
                        "description": "JavaScript code to execute (for 'evaluate' action)"
                    ],
                    "direction": [
                        "type": "string",
                        "enum": ["up", "down", "left", "right"],
                        "description": "Scroll direction (for 'scroll' action)"
                    ],
                    "fullPage": [
                        "type": "boolean",
                        "description": "Whether to capture full scrollable page (for 'screenshot' action). Default: false"
                    ],
                    "value": [
                        "type": "string",
                        "description": "Value to select (for 'select' dropdown action)"
                    ],
                    "checked": [
                        "type": "boolean",
                        "description": "Whether checkbox should be checked (for 'set_checked' action)"
                    ],
                    "timeout": [
                        "type": "number",
                        "description": "Timeout in seconds for wait actions. Default: 10"
                    ],
                    "tag": [
                        "type": "string",
                        "description": "HTML tag filter for click_text (e.g., 'button', 'a')"
                    ],
                    "delay": [
                        "type": "integer",
                        "description": "Delay between keystrokes in ms for 'type' action. Default: 50"
                    ]
                ],
                "required": ["action"]
            ]
        ]
    }
    
    /// Simplified schema for compact tool descriptions
    public static var compactSchema: String {
        """
        browser(action, url?, selector?, text?, script?, direction?, fullPage?, value?, checked?, timeout?, tag?, delay?)
        
        Actions:
        - navigate(url): Go to URL
        - screenshot(fullPage?): Capture page
        - extract_text: Get page text
        - extract_links: Get all links
        - click(selector): Click element
        - click_text(text, tag?): Click by text
        - fill(selector, text): Fill input
        - type(selector, text, delay?): Type with keystrokes
        - select(selector, value): Select dropdown
        - scroll(direction): Scroll page
        - wait_for_element(selector, timeout?): Wait for element
        - evaluate(script): Run JavaScript
        """
    }
}
