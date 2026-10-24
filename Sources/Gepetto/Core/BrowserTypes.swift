//
//  BrowserTypes.swift
//  Gepetto
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
    
    /// Whether pages may run their own JavaScript. Off disables page
    /// scripts only: the engine's observation script and
    /// `evaluateJavaScript` keep working, so the agent can still read and
    /// drive the page.
    public let javaScriptEnabled: Bool
    
    /// Whether to block images for faster loading. Uses a content rule
    /// list, which compiles in the background right after the engine is
    /// created, so a page loaded in that first moment may still show images.
    public let blockImages: Bool

    /// Keep cookies, storage and cache in memory for this engine only
    /// (`WKWebsiteDataStore.nonPersistent()`), so nothing signed into during
    /// a run outlives the engine. Off by default: the engine shares the
    /// app's persistent store, and sign-ins made during a takeover carry
    /// over to later runs (`BrowserEngine.clearWebsiteData()` removes them).
    public let usesEphemeralDataStore: Bool

    /// Identify as Safari on this device rather than as a bare in-app web
    /// view. Sites serve their normal pages to Safari, while many give an
    /// unnamed WKWebView a degraded or blocked experience (Google's OAuth
    /// refuses "embedded" browsers outright, which would break sign-in
    /// during a takeover). This only sets the application name part of
    /// the user agent; it does not change what the engine is.
    public let presentsAsSafari: Bool
    
    /// Default configuration
    public static let `default` = BrowserConfiguration()
    
    /// Fast configuration (blocks images)
    public static let fast = BrowserConfiguration(blockImages: true)
    
    public init(
        userAgent: String? = nil,
        navigationTimeout: TimeInterval = 30,
        javaScriptEnabled: Bool = true,
        blockImages: Bool = false,
        presentsAsSafari: Bool = true,
        usesEphemeralDataStore: Bool = false
    ) {
        self.userAgent = userAgent
        self.navigationTimeout = navigationTimeout
        self.javaScriptEnabled = javaScriptEnabled
        self.blockImages = blockImages
        self.presentsAsSafari = presentsAsSafari
        self.usesEphemeralDataStore = usesEphemeralDataStore
    }

    /// The application-name suffix Safari uses on this OS version, e.g.
    /// "Version/26.0 Mobile/15E148 Safari/604.1" on iOS.
    public static var safariApplicationName: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        return "Version/\(v.majorVersion).\(v.minorVersion) Mobile/15E148 Safari/604.1"
        #else
        return "Version/\(v.majorVersion).\(v.minorVersion) Safari/605.1.15"
        #endif
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
