//
//  AgentOutputParserTests.swift
//  GepettoTests
//
//  The parser has to cope with what small models actually produce.
//

import XCTest
@testable import Gepetto

final class AgentOutputParserTests: XCTestCase {

    private func parse(_ s: String) -> AgentDecision? {
        if case .success(let d) = AgentOutputParser.parse(s) { return d }
        return nil
    }

    func testCanonicalFormat() {
        let d = parse(#"{"evaluation":"ok","memory":"on HN","thought":"open login","action":{"name":"click","index":3}}"#)
        XCTAssertEqual(d?.action, .click(index: 3))
        XCTAssertEqual(d?.memory, "on HN")
        XCTAssertEqual(d?.thought, "open login")
    }

    func testFlatFormat() {
        XCTAssertEqual(parse(#"{"action":"type","index":2,"text":"hello","submit":true}"#)?.action, .type(index: 2, text: "hello", submit: true))
        XCTAssertEqual(parse(#"{"action":"scroll","direction":"up"}"#)?.action, .scroll(direction: .up))
        XCTAssertEqual(parse(#"{"action":"done","answer":"42","success":true}"#)?.action, .done(answer: "42", success: true))
    }

    func testLegacyToolCallEnvelope() {
        let text = """
        Sure, let me open it.
        <tool_call>
        {"name":"browser","arguments":{"action":"navigate","url":"https://news.ycombinator.com"}}
        </tool_call>
        """
        XCTAssertEqual(parse(text)?.action, .navigate(url: "https://news.ycombinator.com"))
    }

    func testBrowserUseStyleList() {
        XCTAssertEqual(parse(#"{"action":[{"click_element":{"index":7}}]}"#)?.action, .click(index: 7))
        XCTAssertEqual(parse(#"{"action":{"input_text":{"index":1,"text":"cats"}}}"#)?.action, .type(index: 1, text: "cats", submit: false))
    }

    func testProseAroundJSONAndCodeFence() {
        let text = """
        I will click the login link.
        ```json
        {"thought": "login first", "action": {"name": "click", "index": "4"}}
        ```
        """
        XCTAssertEqual(parse(text)?.action, .click(index: 4))
    }

    func testTrailingCommasSingleQuotesAndPythonBooleans() {
        XCTAssertEqual(parse(#"{'action': 'type', 'index': 5, 'text': 'x', 'submit': True,}"#)?.action, .type(index: 5, text: "x", submit: true))
    }

    func testThinkBlockIsIgnored() {
        let text = "<think>{\"action\":\"click\",\"index\":99}</think>{\"action\":\"back\"}"
        XCTAssertEqual(parse(text)?.action, .back)
    }

    func testBareKeyForms() {
        XCTAssertEqual(parse(#"{"click": 2}"#)?.action, .click(index: 2))
        XCTAssertEqual(parse(#"{"navigate": "https://example.com"}"#)?.action, .navigate(url: "https://example.com"))
        XCTAssertEqual(parse(#"{"ask_user": "Please log in"}"#)?.action, .askUser(question: "Please log in"))
    }

    func testPlainAnswerBecomesDone() {
        XCTAssertEqual(parse("The top story is about Rust.")?.action, .done(answer: "The top story is about Rust.", success: true))
        XCTAssertEqual(parse("Done: it cost $12")?.action, .done(answer: "it cost $12", success: true))
    }

    func testPlainAnswerRejectedWhenNotAllowed() {
        if case .failure(let f) = AgentOutputParser.parse("Let me think about that.", allowPlainAnswer: false) {
            XCTAssertEqual(f, .noJSON)
        } else {
            XCTFail("expected failure")
        }
    }

    func testKeyNormalisation() {
        XCTAssertEqual(parse(#"{"action":"press","key":"enter"}"#)?.action, .press(key: "Enter"))
        XCTAssertEqual(parse(#"{"action":"press","key":"esc"}"#)?.action, .press(key: "Escape"))
    }

    func testWaitClamps() {
        XCTAssertEqual(parse(#"{"action":"wait","seconds":60}"#)?.action, .wait(seconds: 10))
    }

    func testPartialThoughtWhileStreaming() {
        XCTAssertEqual(AgentOutputParser.partialThought(in: #"{"evaluation":"ok","thought":"scroll down to the res"#), "scroll down to the res")
        XCTAssertNil(AgentOutputParser.partialThought(in: #"{"evaluation":"ok","thou"#))
    }

    func testUnknownActionIsRejected() {
        if case .failure = AgentOutputParser.parse(#"{"action":"teleport","index":1}"#, allowPlainAnswer: false) {} else {
            XCTFail("unknown action should not parse")
        }
    }

    func testReadableAnswerFlattensJSONObjects() {
        let json = #"{"title": "Air Purifiers as White Noise Machines", "posted_by": "luu"}"#
        XCTAssertEqual(AgentOutputParser.readableAnswer(json),
                       "Posted by: luu\nTitle: Air Purifiers as White Noise Machines")
        XCTAssertEqual(AgentOutputParser.readableAnswer(#"["a", "b"]"#), "a, b")
        XCTAssertEqual(AgentOutputParser.readableAnswer("The top story is X, posted by luu."),
                       "The top story is X, posted by luu.")
        XCTAssertEqual(AgentOutputParser.readableAnswer("{not json"), "{not json")
    }
}
