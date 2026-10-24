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
        XCTAssertEqual(parse(#"{"action":{"name":"hand_over","reason":"Sign in"}}"#)?.action, .handOver(reason: "Sign in"))
        XCTAssertEqual(parse(#"{"action":"takeover","reason":"Enter the code"}"#)?.action, .handOver(reason: "Enter the code"))
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

    func testReadableAnswerDropsNullsAndSpellsOutBooleans() {
        XCTAssertEqual(AgentOutputParser.readableAnswer(#"{"answer": null, "title": "X"}"#), "Title: X")
        XCTAssertEqual(AgentOutputParser.readableAnswer(#"{"in_stock": true}"#), "In stock: true")
    }

    // MARK: Plain prose

    func testNarrationIsNeverAnAnswer() {
        for text in ["Let me click the Sign in link first.",
                     "I will click the first story link to read it.",
                     "Next I need to scroll down.",
                     "I need to scroll down to find the login link.",
                     "I should open the menu.",
                     "Okay, I will search for it.",
                     "**Action:** click index 3"] {
            if case .success(let d) = AgentOutputParser.parse(text, allowPlainAnswer: true) {
                XCTFail("\(text) parsed as \(d.action)")
            }
        }
    }

    func testRefusalIsAnUnsuccessfulAnswer() {
        let text = "I'm sorry, but I can't help with that."
        XCTAssertEqual(parse(text)?.action, .done(answer: text, success: false))
    }

    func testFirstPlainReplyIsNotAnAnswer() {
        // The loop passes allowPlainAnswer only for the second non-JSON reply in a row.
        if case .success = AgentOutputParser.parse("The top story is about Rust.", allowPlainAnswer: false) {
            XCTFail("a first plain reply gets the format reminder; it does not end the task")
        }
    }

    func testCutOffThinkBlockIsNotAnAnswer() {
        if case .success = AgentOutputParser.parse("<think>I should click [3] because", allowPlainAnswer: true) {
            XCTFail("a reasoning block cut off by the token limit is not an answer")
        }
        XCTAssertFalse(AgentOutputParser.isPlainProse("<think>I should click [3] because"))
        XCTAssertTrue(AgentOutputParser.isPlainProse("The answer is 4."))
        XCTAssertFalse(AgentOutputParser.isPlainProse(#"{"action":"back"}"#))
    }

    // MARK: Function calls, nested arguments, odd keys

    func testFunctionCallShapes() {
        XCTAssertEqual(parse(#"{"name":"click","arguments":{"index":3}}"#)?.action, .click(index: 3))
        XCTAssertEqual(parse("<tool_call>\n{\"name\": \"click\", \"arguments\": {\"index\": 3}}\n</tool_call>")?.action, .click(index: 3))
        XCTAssertEqual(parse(#"{"name":"type","arguments":"{\"index\":2,\"text\":\"hi\"}"}"#)?.action, .type(index: 2, text: "hi", submit: false))
        let nested = parse(#"{"thought":"x","action":{"name":"click","arguments":{"index":3}}}"#)
        XCTAssertEqual(nested?.action, .click(index: 3))
        XCTAssertEqual(nested?.thought, "x")
        XCTAssertEqual(parse(#"{"name":"click","index":3}"#)?.action, .click(index: 3))
    }

    func testKeysThatDifferOnlyByCaseDoNotCrash() {
        XCTAssertEqual(parse(#"{"action":"click","index":3,"Index":3}"#)?.action, .click(index: 3))
        XCTAssertEqual(parse(#"{"thought":"open login","Thought":"open login","action":{"action":"back"}}"#)?.action, .back)
        // The spelling that is already lower case wins.
        XCTAssertEqual(parse(#"{"action":{"name":"click","index":3,"INDEX":4}}"#)?.action, .click(index: 3))
    }

    func testStrayKeyBesideABrokenActionIsNotPromoted() {
        for text in [#"{"thought":"x","action":{"action":"click","index":"N"},"answer":"not yet"}"#,
                     #"{"thought":"x","action":{"name":"click_button","index":3},"answer":"not yet"}"#,
                     #"{"action":{"action":"click","index":"N"},"key":"Enter"}"#] {
            if case .success(let d) = AgentOutputParser.parse(text, allowPlainAnswer: false) {
                XCTFail("\(text) parsed as \(d.action)")
            }
        }
        // With no action at all, a bare answer is still a final answer.
        XCTAssertEqual(parse(#"{"thought":"found it","answer":"42"}"#)?.action, .done(answer: "42", success: true))
    }

    func testNonStringValuesAreKept() {
        XCTAssertEqual(parse(#"{"action":"done","answer":["Story A","Story B","Story C"],"success":true}"#)?.action,
                       .done(answer: "Story A\nStory B\nStory C", success: true))
        XCTAssertEqual(parse(#"{"action":"done","answer":{"title":"Rust 2.0","points":312}}"#)?.action,
                       .done(answer: "Points: 312\nTitle: Rust 2.0", success: true))
        XCTAssertEqual(parse(#"{"action":"done","answer":42}"#)?.action, .done(answer: "42", success: true))
        XCTAssertEqual(parse(#"{"action":"type","index":3,"text":94105}"#)?.action, .type(index: 3, text: "94105", submit: false))
        XCTAssertEqual(parse(#"{"memory":["fact1","fact2"],"action":"back"}"#)?.memory, "fact1; fact2")
        // An answer next to the action object fills it in.
        XCTAssertEqual(parse(#"{"thought":"x","action":{"name":"done"},"answer":"The top story is X"}"#)?.action,
                       .done(answer: "The top story is X", success: true))
    }

    func testLenientScanFindsTheActionInsideABrokenReply() {
        let text = #"{"evaluation":"the "login" link worked","memory":"on login page","thought":"type the username","action":{"action":"type","index":1,"text":"jc","submit":false}}"#
        XCTAssertEqual(parse(text)?.action, .type(index: 1, text: "jc", submit: false))
    }

    func testSetCheckedAndScrollToShapes() {
        XCTAssertEqual(parse(#"{"action":"set_checked","index":5,"checked":false}"#)?.action, .setChecked(index: 5, checked: false))
        XCTAssertEqual(parse(#"{"action":"scroll_to","index":3}"#)?.action, .scrollTo(index: 3))
    }
}
