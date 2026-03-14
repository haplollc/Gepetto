//
//  BrowserErrorTests.swift
//  GepettoTests
//

import XCTest
@testable import Gepetto

final class BrowserErrorTests: XCTestCase {
    
    // MARK: - Error Description Tests
    
    func testInvalidURLError() {
        let error = BrowserError.invalidURL("not a url")
        XCTAssertTrue(error.localizedDescription.contains("Invalid URL"))
        XCTAssertTrue(error.localizedDescription.contains("not a url"))
    }
    
    func testNavigationFailedError() {
        let error = BrowserError.navigationFailed("Connection refused")
        XCTAssertTrue(error.localizedDescription.contains("Navigation failed"))
        XCTAssertTrue(error.localizedDescription.contains("Connection refused"))
    }
    
    func testElementNotFoundError() {
        let error = BrowserError.elementNotFound("#button", "No matching element")
        XCTAssertTrue(error.localizedDescription.contains("Element not found"))
        XCTAssertTrue(error.localizedDescription.contains("#button"))
    }
    
    func testScreenshotFailedError() {
        let error = BrowserError.screenshotFailed("Memory limit exceeded")
        XCTAssertTrue(error.localizedDescription.contains("Screenshot failed"))
    }
    
    func testJavaScriptError() {
        let error = BrowserError.javaScriptError("ReferenceError: x is not defined")
        XCTAssertTrue(error.localizedDescription.contains("JavaScript error"))
    }
    
    func testActionFailedError() {
        let error = BrowserError.actionFailed("click", "Element not interactable")
        XCTAssertTrue(error.localizedDescription.contains("click failed"))
    }
    
    func testTimeoutError() {
        let error = BrowserError.timeout("Element not found: #modal")
        XCTAssertTrue(error.localizedDescription.contains("Timeout"))
    }
    
    func testNotInitializedError() {
        let error = BrowserError.notInitialized
        XCTAssertTrue(error.localizedDescription.contains("not initialized"))
    }
    
    func testPlatformNotSupportedError() {
        let error = BrowserError.platformNotSupported
        XCTAssertTrue(error.localizedDescription.contains("not supported"))
    }
    
    // MARK: - User Message Tests
    
    func testUserMessageForInvalidURL() {
        let error = BrowserError.invalidURL("test")
        XCTAssertFalse(error.userMessage.isEmpty)
        XCTAssertTrue(error.userMessage.contains("URL"))
    }
    
    func testUserMessageForTimeout() {
        let error = BrowserError.timeout("test")
        XCTAssertFalse(error.userMessage.isEmpty)
        XCTAssertTrue(error.userMessage.contains("try again"))
    }
    
    func testAllErrorsHaveUserMessages() {
        let errors: [BrowserError] = [
            .invalidURL("test"),
            .navigationFailed("test"),
            .elementNotFound("sel", "msg"),
            .screenshotFailed("test"),
            .javaScriptError("test"),
            .actionFailed("act", "msg"),
            .timeout("test"),
            .notInitialized,
            .platformNotSupported
        ]
        
        for error in errors {
            XCTAssertFalse(error.userMessage.isEmpty, "Error \(error) should have a user message")
        }
    }
}
