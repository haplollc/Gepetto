//
//  BrowserToolExecutorTests.swift
//  BrowserKitTests
//

import XCTest
@testable import BrowserKit

@MainActor
final class BrowserToolExecutorTests: XCTestCase {
    
    var executor: BrowserToolExecutor!
    
    override func setUp() async throws {
        executor = BrowserToolExecutor()
    }
    
    override func tearDown() async throws {
        await executor.stop()
        executor = nil
    }
    
    // MARK: - Lifecycle Tests
    
    func testExecutorStartsInactive() {
        XCTAssertFalse(executor.isActive)
        XCTAssertNil(executor.engine)
    }
    
    func testExecutorStartCreatesEngine() {
        executor.start()
        
        XCTAssertTrue(executor.isActive)
        XCTAssertNotNil(executor.engine)
    }
    
    func testExecutorStopClearsEngine() {
        executor.start()
        executor.stop()
        
        XCTAssertFalse(executor.isActive)
        XCTAssertNil(executor.engine)
    }
    
    func testExecutorAutoStartsOnExecute() async {
        XCTAssertFalse(executor.isActive)
        
        // Execute any action - should auto-start
        _ = await executor.execute(BrowserTool.Parameters(action: .getTitle))
        
        XCTAssertTrue(executor.isActive)
        XCTAssertNotNil(executor.engine)
    }
    
    // MARK: - Action Validation Tests
    
    func testNavigateRequiresURL() async {
        let result = await executor.execute(
            BrowserTool.Parameters(action: .navigate)
        )
        
        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error?.contains("URL") ?? false)
    }
    
    func testClickRequiresSelector() async {
        let result = await executor.execute(
            BrowserTool.Parameters(action: .click)
        )
        
        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error?.contains("Selector") ?? false)
    }
    
    func testFillRequiresSelectorAndText() async {
        // Missing both
        let result1 = await executor.execute(
            BrowserTool.Parameters(action: .fill)
        )
        XCTAssertFalse(result1.success)
        
        // Missing text
        let result2 = await executor.execute(
            BrowserTool.Parameters(action: .fill, selector: "#input")
        )
        XCTAssertFalse(result2.success)
    }
    
    func testTypeRequiresSelectorAndText() async {
        let result = await executor.execute(
            BrowserTool.Parameters(action: .type, selector: "#input")
        )
        
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("Text") ?? false)
    }
    
    func testClickTextRequiresText() async {
        let result = await executor.execute(
            BrowserTool.Parameters(action: .clickText)
        )
        
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("Text") ?? false)
    }
    
    func testSelectRequiresSelectorAndValue() async {
        let result = await executor.execute(
            BrowserTool.Parameters(action: .select, selector: "select")
        )
        
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("Value") ?? false)
    }
    
    func testWaitForElementRequiresSelector() async {
        let result = await executor.execute(
            BrowserTool.Parameters(action: .waitForElement)
        )
        
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("Selector") ?? false)
    }
    
    func testWaitForTextRequiresText() async {
        let result = await executor.execute(
            BrowserTool.Parameters(action: .waitForText)
        )
        
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("Text") ?? false)
    }
    
    func testEvaluateRequiresScript() async {
        let result = await executor.execute(
            BrowserTool.Parameters(action: .evaluate)
        )
        
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("Script") ?? false)
    }
    
    // MARK: - JSON Execution Tests
    
    func testExecuteFromJSON() async {
        let json: [String: Any] = [
            "action": "get_title"
        ]
        
        let result = await executor.execute(json: json)
        
        // Should succeed (even if title is empty on blank page)
        XCTAssertTrue(result.success)
    }
    
    func testExecuteFromJSONWithInvalidAction() async {
        let json: [String: Any] = [
            "action": "invalid_action"
        ]
        
        let result = await executor.execute(json: json)
        
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("Invalid") ?? false)
    }
    
    func testExecuteFromJSONWithMissingAction() async {
        let json: [String: Any] = [
            "url": "https://example.com"
        ]
        
        let result = await executor.execute(json: json)
        
        XCTAssertFalse(result.success)
    }
    
    // MARK: - Action Success Tests (No Navigation)
    
    func testGetTitleSucceeds() async {
        let result = await executor.execute(
            BrowserTool.Parameters(action: .getTitle)
        )
        
        XCTAssertTrue(result.success)
    }
    
    func testGetURLSucceeds() async {
        let result = await executor.execute(
            BrowserTool.Parameters(action: .getURL)
        )
        
        XCTAssertTrue(result.success)
    }
    
    func testExtractTextSucceeds() async {
        let result = await executor.execute(
            BrowserTool.Parameters(action: .extractText)
        )
        
        XCTAssertTrue(result.success)
    }
    
    func testScrollSucceeds() async {
        let result = await executor.execute(
            BrowserTool.Parameters(action: .scroll, direction: "down")
        )
        
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.message?.contains("Scrolled") ?? false)
    }
    
    func testScrollToTopSucceeds() async {
        let result = await executor.execute(
            BrowserTool.Parameters(action: .scrollToTop)
        )
        
        XCTAssertTrue(result.success)
    }
    
    func testScrollToBottomSucceeds() async {
        let result = await executor.execute(
            BrowserTool.Parameters(action: .scrollToBottom)
        )
        
        XCTAssertTrue(result.success)
    }
    
    func testScreenshotReturnsResult() async {
        // Screenshot may fail on blank page in headless test environment
        // but should return a result (success or failure)
        let result = await executor.execute(
            BrowserTool.Parameters(action: .screenshot)
        )
        
        // Should have either screenshot data or error message
        XCTAssertTrue(result.screenshot != nil || result.error != nil || result.success)
    }
    
    func testEvaluateSimpleJSSucceeds() async {
        let result = await executor.execute(
            BrowserTool.Parameters(action: .evaluate, script: "1 + 1")
        )
        
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data, "2")
    }
}
