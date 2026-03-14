//
//  BrowserTypesTests.swift
//  BrowserKitTests
//

import XCTest
@testable import BrowserKit

final class BrowserTypesTests: XCTestCase {
    
    // MARK: - Configuration Tests
    
    func testDefaultConfiguration() {
        let config = BrowserConfiguration.default
        
        XCTAssertNil(config.userAgent)
        XCTAssertEqual(config.navigationTimeout, 30)
        XCTAssertTrue(config.javaScriptEnabled)
        XCTAssertFalse(config.blockImages)
    }
    
    func testFastConfiguration() {
        let config = BrowserConfiguration.fast
        
        XCTAssertTrue(config.blockImages)
    }
    
    func testCustomConfiguration() {
        let config = BrowserConfiguration(
            userAgent: "CustomAgent/1.0",
            navigationTimeout: 60,
            javaScriptEnabled: false,
            blockImages: true
        )
        
        XCTAssertEqual(config.userAgent, "CustomAgent/1.0")
        XCTAssertEqual(config.navigationTimeout, 60)
        XCTAssertFalse(config.javaScriptEnabled)
        XCTAssertTrue(config.blockImages)
    }
    
    // MARK: - Navigation Result Tests
    
    func testNavigationResult() {
        let result = NavigationResult(
            url: "https://example.com",
            title: "Example",
            statusCode: 200
        )
        
        XCTAssertEqual(result.url, "https://example.com")
        XCTAssertEqual(result.title, "Example")
        XCTAssertEqual(result.statusCode, 200)
    }
    
    // MARK: - Scroll Direction Tests
    
    func testScrollDirectionRawValues() {
        XCTAssertEqual(ScrollDirection.up.rawValue, "up")
        XCTAssertEqual(ScrollDirection.down.rawValue, "down")
        XCTAssertEqual(ScrollDirection.left.rawValue, "left")
        XCTAssertEqual(ScrollDirection.right.rawValue, "right")
    }
    
    func testScrollDirectionDecoding() throws {
        let json = "\"down\""
        let data = json.data(using: .utf8)!
        let direction = try JSONDecoder().decode(ScrollDirection.self, from: data)
        
        XCTAssertEqual(direction, .down)
    }
    
    // MARK: - Link Info Tests
    
    func testLinkInfo() {
        let link = LinkInfo(
            href: "https://example.com/page",
            text: "Click here",
            title: "Example Page"
        )
        
        XCTAssertEqual(link.href, "https://example.com/page")
        XCTAssertEqual(link.text, "Click here")
        XCTAssertEqual(link.title, "Example Page")
    }
    
    // MARK: - Form Field Info Tests
    
    func testFormFieldInfo() {
        let field = FormFieldInfo(
            type: "email",
            name: "user_email",
            id: "email-input",
            placeholder: "Enter email",
            value: "",
            selector: "#email-input"
        )
        
        XCTAssertEqual(field.type, "email")
        XCTAssertEqual(field.name, "user_email")
        XCTAssertEqual(field.id, "email-input")
        XCTAssertEqual(field.placeholder, "Enter email")
        XCTAssertEqual(field.selector, "#email-input")
    }
    
    // MARK: - Browser State Tests
    
    func testBrowserStateEncoding() throws {
        let state = BrowserState(
            url: "https://example.com",
            title: "Example",
            canGoBack: true,
            canGoForward: false,
            scrollPosition: CGPoint(x: 0, y: 100)
        )
        
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BrowserState.self, from: data)
        
        XCTAssertEqual(decoded.url, state.url)
        XCTAssertEqual(decoded.title, state.title)
        XCTAssertEqual(decoded.canGoBack, state.canGoBack)
        XCTAssertEqual(decoded.canGoForward, state.canGoForward)
    }
}
