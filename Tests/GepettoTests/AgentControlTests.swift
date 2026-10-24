//
//  AgentControlTests.swift
//  GepettoTests
//

import XCTest
@testable import Gepetto

final class AgentControlTests: XCTestCase {

    // MARK: Sensitive-action classifier

    func testPurchaseWords() {
        XCTAssertEqual(SensitiveActionCategory.classify(label: "Place your order"), .purchase)
        XCTAssertEqual(SensitiveActionCategory.classify(label: "Buy now"), .purchase)
        XCTAssertEqual(SensitiveActionCategory.classify(label: "Checkout"), .purchase)
    }

    func testSendDeleteAccount() {
        XCTAssertEqual(SensitiveActionCategory.classify(label: "Post"), .send)
        XCTAssertEqual(SensitiveActionCategory.classify(label: "Send message"), .send)
        XCTAssertEqual(SensitiveActionCategory.classify(label: "Delete"), .delete)
        XCTAssertEqual(SensitiveActionCategory.classify(label: "Change password"), .account)
    }

    func testHarmlessLabels() {
        XCTAssertNil(SensitiveActionCategory.classify(label: "Sign in"))
        XCTAssertNil(SensitiveActionCategory.classify(label: "Search"))
        XCTAssertNil(SensitiveActionCategory.classify(label: "Reject all"))
        XCTAssertNil(SensitiveActionCategory.classify(label: "Deliver to my address"))
    }

    func testGenericConfirmNextToMoneyIsAPurchase() {
        XCTAssertEqual(SensitiveActionCategory.classify(label: "Confirm", pageText: "Total: $42.00"), .purchase)
        XCTAssertNil(SensitiveActionCategory.classify(label: "Confirm", pageText: "Confirm your email address"))
    }

    func testDefaultRules() {
        let rules = SensitiveActionRules.default
        XCTAssertEqual(rules.policy(for: .purchase), .askFirst)
        XCTAssertEqual(rules.policy(for: .account), .block)
        XCTAssertEqual(SensitiveActionRules.permissive.policy(for: .purchase), .allow)
    }

    // MARK: Control state

    func testControlStateHelpers() {
        XCTAssertTrue(AgentControlState.waitingForUser(.takeover(.userInitiated)).isHumanDriving)
        XCTAssertFalse(AgentControlState.waitingForUser(.question("?")).isHumanDriving)
        XCTAssertTrue(AgentControlState.paused.isActive)
        XCTAssertFalse(AgentControlState.finished(success: true).isActive)
    }

    // MARK: Hand-back summary

    func testHandBackSummaryText() {
        let s = HandBackSummary(seconds: 41.6, urlBefore: "https://a.com/login", urlAfter: "https://a.com/home",
                                titleAfter: "Home", note: "I logged in", changedFields: ["Email (\"jc@x.com\")", "Password (hidden)"],
                                blockersBefore: [.login], blockersAfter: [])
        let t = s.modelText
        XCTAssertTrue(t.contains("42 seconds"))
        XCTAssertTrue(t.contains("changed from https://a.com/login to https://a.com/home"))
        XCTAssertTrue(t.contains("Resolved: login"))
        XCTAssertTrue(t.contains("The user says: I logged in"))
        XCTAssertTrue(t.contains("Do not redo what the user did"))
    }

    // MARK: Steps

    func testHistoryLine() {
        var step = AgentStep(number: 3, action: .click(index: 4), label: "Clicking “Go” button", thought: nil)
        step.outcome = "clicked. Effect: URL changed."
        XCTAssertEqual(step.historyLine, "3. click([4]) → clicked. Effect: URL changed.")
        step.succeeded = false
        step.outcome = "failed: no element"
        XCTAssertEqual(step.historyLine, "3. click([4]) → FAILED: failed: no element")
    }

    // MARK: Agent control API on a fresh agent

    @MainActor
    func testControlCallsAreNoOpsWhenIdle() {
        let agent = BrowserAgent()
        agent.pause(); agent.resume(); agent.takeOver(); agent.handBack(); agent.respond(allow: true); agent.answer("x")
        XCTAssertEqual(agent.controlState, .idle)
    }

    func testTaskAsksForPageAction() {
        XCTAssertTrue(AgentLoopHeuristics.taskAsksForPageAction("Open demoblaze.com and add this phone to the cart."))
        XCTAssertTrue(AgentLoopHeuristics.taskAsksForPageAction("Sign up for the newsletter on example.com"))
        XCTAssertTrue(AgentLoopHeuristics.taskAsksForPageAction("Tap the Add to cart button."))
        XCTAssertFalse(AgentLoopHeuristics.taskAsksForPageAction("Go to news.ycombinator.com and tell me the title of the top story."))
        XCTAssertFalse(AgentLoopHeuristics.taskAsksForPageAction("What is the weather in Paris today?"))
        // Whole words only: "address" is not "add", "registered" is not "register".
        XCTAssertFalse(AgentLoopHeuristics.taskAsksForPageAction("Find the address of the registered office."))
    }
}
