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

    @MainActor
    func testSecondRunIsRefusedWhileOneIsActive() async {
        let agent = BrowserAgent()
        agent.runInProgress = true   // as if another run were still going
        var reason: String?
        await agent.run(task: "anything", engine: SilentEngine()) { event in
            if case .failed(let r, _) = event { reason = r }
        }
        XCTAssertEqual(reason, "A task is already running.")
        XCTAssertEqual(agent.controlState, .idle)
        XCTAssertNil(agent.executor, "a refused run must not touch the browser")
    }

    // MARK: Classifier: ordinary buttons

    func testFilterSearchAndLinkButtonsAreNotSensitive() {
        for label in ["Apply filters", "Apply filter", "Clear all filters", "Share link", "Copy link",
                      "Submit search", "Search", "Apply 3 filters", "Transfers"] {
            XCTAssertNil(SensitiveActionCategory.classify(label: label), label)
        }
    }

    func testSpecificSendOrderAndMoneyWordsStaySensitive() {
        XCTAssertEqual(SensitiveActionCategory.classify(label: "Apply now"), .send)
        XCTAssertEqual(SensitiveActionCategory.classify(label: "Submit application"), .send)
        XCTAssertEqual(SensitiveActionCategory.classify(label: "Share post"), .send)
        XCTAssertEqual(SensitiveActionCategory.classify(label: "Submit"), .send)
        XCTAssertEqual(SensitiveActionCategory.classify(label: "Submit order"), .purchase)
        XCTAssertEqual(SensitiveActionCategory.classify(label: "Send money"), .purchase)
        // Moving money is asked about, not refused outright.
        XCTAssertEqual(SensitiveActionCategory.classify(label: "Transfer"), .purchase)
        XCTAssertEqual(SensitiveActionCategory.classify(label: "Clear all"), .delete)
    }

    // MARK: Secrets

    func testTypingIntoAPasswordFieldNeverShowsTheText() {
        let field = PageSnapshot.Element(index: 0, ref: "r0", kind: "input", tag: "input", text: "Password", inputType: "password")
        let snap = PageSnapshot(url: "https://a.com/login", title: "Sign in", elements: [field])
        let action = AgentAction.type(index: 0, text: "hunter2", submit: false)
        XCTAssertEqual(action.humanLabel(in: snap), "Typing into “Password” field")
        let shown = action.redactingSecrets(in: snap)
        XCTAssertEqual(shown, .type(index: 0, text: AgentAction.secretMask, submit: false))
        XCTAssertEqual(shown.compactDescription, "type([0], <hidden>)")
        XCTAssertFalse(shown.humanLabel(in: nil).contains("hunter2"))
        // Ordinary fields still show what is typed.
        XCTAssertEqual(AgentAction.type(index: 1, text: "cats", submit: false).humanLabel(in: nil), "Typing “cats” into element 1")
    }

    func testHandBackListsFieldLabelsNotValues() {
        let before = PageSnapshot(url: "https://a.com/login", title: "Sign in", elements: [
            PageSnapshot.Element(index: 0, ref: "r0", kind: "input", tag: "input", text: "Email", value: ""),
            PageSnapshot.Element(index: 1, ref: "r1", kind: "input", tag: "input", text: "Code", value: "")
        ])
        let after = PageSnapshot(url: "https://a.com/login", title: "Sign in", elements: [
            PageSnapshot.Element(index: 0, ref: "r0", kind: "input", tag: "input", text: "Email", value: "jc@x.com"),
            PageSnapshot.Element(index: 1, ref: "r1", kind: "input", tag: "input", text: "Code", value: "493021")
        ])
        let labels = BrowserAgent.filledFieldLabels(before: before, after: after)
        XCTAssertEqual(labels, ["Email", "Code"])
        let summary = HandBackSummary(seconds: 5, urlBefore: before.url, urlAfter: after.url, titleAfter: after.title,
                                      note: nil, changedFields: labels, blockersBefore: [.twoFactor], blockersAfter: [])
        XCTAssertTrue(summary.modelText.contains("Fields the user filled: Email, Code."))
        XCTAssertFalse(summary.modelText.contains("jc@x.com"))
        XCTAssertFalse(summary.modelText.contains("493021"))
    }

    func testHandBackListsAFilledSecretFieldByLabelOnly() {
        let before = PageSnapshot(url: "https://a.com/login", title: "Sign in", elements: [
            PageSnapshot.Element(index: 0, ref: "r0", kind: "input", tag: "input", text: "Password", inputType: "password")
        ])
        let after = PageSnapshot(url: "https://a.com/login", title: "Sign in", elements: [
            PageSnapshot.Element(index: 0, ref: "r0", kind: "input", tag: "input", text: "Password", value: "hunter2", inputType: "password")
        ])
        XCTAssertNotEqual(after.elements[0].value, "hunter2")
        XCTAssertEqual(BrowserAgent.filledFieldLabels(before: before, after: after), ["Password"])
    }

    // MARK: Loop notes

    func testDeclinedActionNote() {
        XCTAssertEqual(BrowserAgent.declinedNote("Clicking “Post” button"),
                       "The user denied clicking “Post” button. Do not try it again; finish with what you have or ask the user.")
    }

    func testInvalidIndexNoteSpellsOutTheRangeTheSecondTime() {
        let snap = PageSnapshot(url: "https://a.com", title: "A", elements: (0..<10).map {
            PageSnapshot.Element(index: $0, ref: "r\($0)", kind: "link", tag: "a", text: "Link \($0)")
        })
        XCTAssertFalse(BrowserAgent.invalidTargetNote(index: 15, in: snap, showRange: false).contains("0 to 9"))
        XCTAssertTrue(BrowserAgent.invalidTargetNote(index: 15, in: snap, showRange: true).contains("Valid indices on this page are 0 to 9"))
    }

    func testEmptyPageNoteNamesTheFailedNavigation() {
        let reason = BrowserAgent.failureReason("failed: Navigation failed: The resource could not be loaded.")
        XCTAssertEqual(reason, "Navigation failed: The resource could not be loaded")
        XCTAssertEqual(BrowserAgent.emptyPageNote(navigationFailure: reason),
                       "The last navigation failed: Navigation failed: The resource could not be loaded. The page is empty. Navigate to the https:// address or search instead of waiting.")
    }

    // MARK: Navigation targets

    func testOnlyWebAddressesCanBeOpened() {
        XCTAssertEqual(BrowserEngine.webURL(from: "google.com")?.absoluteString, "https://google.com")
        XCTAssertEqual(BrowserEngine.webURL(from: "localhost:8080/x")?.absoluteString, "https://localhost:8080/x")
        XCTAssertEqual(BrowserEngine.webURL(from: " http://a.com/b ")?.absoluteString, "http://a.com/b")
        XCTAssertEqual(BrowserEngine.webURL(from: "//example.com/x")?.absoluteString, "https://example.com/x")
        for text in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "about:blank", "ftp://x.com", "mailto:a@b.com", ""] {
            XCTAssertNil(BrowserEngine.webURL(from: text), text)
        }
    }

    func testBareHostsInATaskPreferHTTPS() {
        XCTAssertEqual(BrowserAgent.preferringHTTPS("http://demoblaze.com", in: "Go to demoblaze.com"), "https://demoblaze.com")
        XCTAssertEqual(BrowserAgent.preferringHTTPS("http://demoblaze.com", in: "Open http://demoblaze.com"), "http://demoblaze.com")
        XCTAssertEqual(BrowserAgent.preferringHTTPS("https://a.com", in: "a.com"), "https://a.com")
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

/// An engine that never says anything, for tests that must not reach a model.
private final class SilentEngine: GepettoAIEngine {
    func stream(messages: [GepettoMessage], systemPrompt: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
