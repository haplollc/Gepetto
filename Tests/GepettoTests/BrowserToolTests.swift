//
//  BrowserToolTests.swift
//  GepettoTests
//

import XCTest
@testable import Gepetto

final class BrowserToolTests: XCTestCase {
    
    // MARK: - Action Tests
    
    func testAllActionsHaveRawValues() {
        for action in BrowserTool.Action.allCases {
            XCTAssertFalse(action.rawValue.isEmpty, "Action \(action) should have a raw value")
        }
    }
    
    func testActionDecoding() throws {
        let json = """
        {"action": "navigate", "url": "https://example.com"}
        """
        let data = json.data(using: .utf8)!
        let params = try JSONDecoder().decode(BrowserTool.Parameters.self, from: data)
        
        XCTAssertEqual(params.action, .navigate)
        XCTAssertEqual(params.url, "https://example.com")
    }
    
    func testActionDecodingWithSelector() throws {
        let json = """
        {"action": "click", "selector": "#submit-button"}
        """
        let data = json.data(using: .utf8)!
        let params = try JSONDecoder().decode(BrowserTool.Parameters.self, from: data)
        
        XCTAssertEqual(params.action, .click)
        XCTAssertEqual(params.selector, "#submit-button")
    }
    
    func testActionDecodingWithAllParams() throws {
        let json = """
        {
            "action": "type",
            "selector": "#search",
            "text": "hello world",
            "delay": 100
        }
        """
        let data = json.data(using: .utf8)!
        let params = try JSONDecoder().decode(BrowserTool.Parameters.self, from: data)
        
        XCTAssertEqual(params.action, .type)
        XCTAssertEqual(params.selector, "#search")
        XCTAssertEqual(params.text, "hello world")
        XCTAssertEqual(params.delay, 100)
    }
    
    // MARK: - Result Tests
    
    func testSuccessResult() {
        let result = BrowserTool.Result.success(message: "Done", data: "Test data")
        
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.message, "Done")
        XCTAssertEqual(result.data, "Test data")
        XCTAssertNil(result.error)
    }
    
    func testFailureResult() {
        let result = BrowserTool.Result.failure("Something went wrong")
        
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "Something went wrong")
    }
    
    func testResultWithLinks() throws {
        let result = BrowserTool.Result(
            success: true,
            message: "Found 2 links",
            links: [
                BrowserTool.LinkResult(href: "https://a.com", text: "Link A"),
                BrowserTool.LinkResult(href: "https://b.com", text: "Link B")
            ]
        )
        
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.links?.count, 2)
        XCTAssertEqual(result.links?[0].href, "https://a.com")
    }
    
    func testResultEncoding() throws {
        let result = BrowserTool.Result(
            success: true,
            message: "Test",
            data: "Data"
        )
        
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(BrowserTool.Result.self, from: data)
        
        XCTAssertEqual(decoded.success, result.success)
        XCTAssertEqual(decoded.message, result.message)
        XCTAssertEqual(decoded.data, result.data)
    }
    
    // MARK: - JSON Schema Tests
    
    func testJSONSchemaHasRequiredFields() {
        let schema = BrowserTool.jsonSchema
        
        XCTAssertEqual(schema["name"] as? String, "browser")
        XCTAssertNotNil(schema["description"])
        XCTAssertNotNil(schema["parameters"])
    }
    
    func testJSONSchemaParameters() {
        let schema = BrowserTool.jsonSchema
        let params = schema["parameters"] as? [String: Any]
        let properties = params?["properties"] as? [String: Any]
        
        XCTAssertNotNil(properties?["action"])
        XCTAssertNotNil(properties?["url"])
        XCTAssertNotNil(properties?["selector"])
        XCTAssertNotNil(properties?["text"])
    }
    
    func testCompactSchemaNotEmpty() {
        let compact = BrowserTool.compactSchema
        XCTAssertFalse(compact.isEmpty)
        XCTAssertTrue(compact.contains("navigate"))
        XCTAssertTrue(compact.contains("screenshot"))
        XCTAssertTrue(compact.contains("click"))
    }
}
