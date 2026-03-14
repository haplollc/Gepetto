//
//  BrowserTypes.swift
//  BrowserKit
//
//  Core types for browser automation.
//

import Foundation

// MARK: - Configuration

/// Configuration options for the browser engine.
public struct BrowserConfiguration: Sendable {
    /// Custom user agent string
    public let userAgent: String?
    
    /// Timeout for navigation in seconds
    public let navigationTimeout: TimeInterval
    
    /// Whether to allow JavaScript
    public let javaScriptEnabled: Bool
    
    /// Whether to block images for faster loading
    public let blockImages: Bool
    
    /// Default configuration
    public static let `default` = BrowserConfiguration()
    
    /// Fast configuration (blocks images)
    public static let fast = BrowserConfiguration(blockImages: true)
    
    public init(
        userAgent: String? = nil,
        navigationTimeout: TimeInterval = 30,
        javaScriptEnabled: Bool = true,
        blockImages: Bool = false
    ) {
        self.userAgent = userAgent
        self.navigationTimeout = navigationTimeout
        self.javaScriptEnabled = javaScriptEnabled
        self.blockImages = blockImages
    }
}

// MARK: - Navigation Result

/// Result of a navigation action.
public struct NavigationResult: Sendable {
    /// Final URL after any redirects
    public let url: String
    
    /// Page title
    public let title: String
    
    /// HTTP status code
    public let statusCode: Int
    
    public init(url: String, title: String, statusCode: Int) {
        self.url = url
        self.title = title
        self.statusCode = statusCode
    }
}

// MARK: - Scroll Direction

/// Direction for scrolling.
public enum ScrollDirection: String, Sendable, CaseIterable, Codable {
    case up
    case down
    case left
    case right
}

// MARK: - Link Info

/// Information about a link on the page.
public struct LinkInfo: Sendable {
    public let href: String
    public let text: String
    public let title: String
    
    public init(href: String, text: String, title: String) {
        self.href = href
        self.text = text
        self.title = title
    }
}

// MARK: - Form Field Info

/// Information about a form field.
public struct FormFieldInfo: Sendable {
    public let type: String
    public let name: String
    public let id: String
    public let placeholder: String
    public let value: String
    public let selector: String
    
    public init(type: String, name: String, id: String, placeholder: String, value: String, selector: String) {
        self.type = type
        self.name = name
        self.id = id
        self.placeholder = placeholder
        self.value = value
        self.selector = selector
    }
}

// MARK: - Element Info

/// Information about an element on the page.
public struct ElementInfo: Sendable {
    public let tagName: String
    public let id: String?
    public let className: String?
    public let text: String
    public let isVisible: Bool
    public let rect: CGRect
    
    public init(tagName: String, id: String?, className: String?, text: String, isVisible: Bool, rect: CGRect) {
        self.tagName = tagName
        self.id = id
        self.className = className
        self.text = text
        self.isVisible = isVisible
        self.rect = rect
    }
}

// MARK: - Browser State

/// Current state of the browser for persistence.
public struct BrowserState: Codable, Sendable {
    public let url: String?
    public let title: String?
    public let canGoBack: Bool
    public let canGoForward: Bool
    public let scrollPosition: CGPoint
    
    public init(url: String?, title: String?, canGoBack: Bool, canGoForward: Bool, scrollPosition: CGPoint) {
        self.url = url
        self.title = title
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.scrollPosition = scrollPosition
    }
}
