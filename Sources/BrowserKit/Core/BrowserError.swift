//
//  BrowserError.swift
//  BrowserKit
//
//  Error types for browser automation.
//

import Foundation

/// Errors that can occur during browser automation.
public enum BrowserError: Error, LocalizedError, Sendable {
    /// Invalid URL provided
    case invalidURL(String)
    
    /// Navigation failed
    case navigationFailed(String)
    
    /// Element not found
    case elementNotFound(String, String)
    
    /// Screenshot failed
    case screenshotFailed(String)
    
    /// JavaScript execution error
    case javaScriptError(String)
    
    /// Action failed
    case actionFailed(String, String)
    
    /// Operation timed out
    case timeout(String)
    
    /// Browser not initialized
    case notInitialized
    
    /// Platform not supported
    case platformNotSupported
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .navigationFailed(let message):
            return "Navigation failed: \(message)"
        case .elementNotFound(let selector, let message):
            return "Element not found '\(selector)': \(message)"
        case .screenshotFailed(let message):
            return "Screenshot failed: \(message)"
        case .javaScriptError(let message):
            return "JavaScript error: \(message)"
        case .actionFailed(let action, let message):
            return "\(action) failed: \(message)"
        case .timeout(let message):
            return "Timeout: \(message)"
        case .notInitialized:
            return "Browser not initialized"
        case .platformNotSupported:
            return "Browser automation is not supported on this platform"
        }
    }
    
    /// User-friendly message for display in UI
    public var userMessage: String {
        switch self {
        case .invalidURL:
            return "The URL entered is not valid. Please check and try again."
        case .navigationFailed:
            return "Could not load the page. Please check your connection."
        case .elementNotFound:
            return "Could not find the element on the page."
        case .screenshotFailed:
            return "Could not capture the page."
        case .javaScriptError:
            return "An error occurred while interacting with the page."
        case .actionFailed:
            return "The action could not be completed."
        case .timeout:
            return "The operation took too long. Please try again."
        case .notInitialized:
            return "The browser is not ready. Please try again."
        case .platformNotSupported:
            return "This feature requires a different platform."
        }
    }
}
