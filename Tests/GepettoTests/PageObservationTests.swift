//
//  PageObservationTests.swift
//  GepettoTests
//
//  The model's view of a page, built from real HTML in a real WKWebView:
//  element lines, stable refs, actions by index, consent dismissal,
//  blocker detection, settle detection.
//

import XCTest
import WebKit
@testable import Gepetto

@MainActor
final class PageObservationTests: XCTestCase {

    private var engine: BrowserEngine!
    #if os(macOS)
    private var window: NSWindow!
    #endif

    override func setUp() async throws {
        engine = BrowserEngine()
        engine.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        #if os(macOS)
        // WKWebView lays out (and reports geometry) only inside a window.
        window = NSWindow(contentRect: engine.webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = engine.webView
        window.orderFront(nil)
        #endif
    }

    override func tearDown() async throws {
        #if os(macOS)
        window?.orderOut(nil)
        window = nil
        #endif
        engine = nil
    }

    private func load(_ html: String) async throws {
        let done = expectation(description: "load")
        let token = engine.webView.observe(\.isLoading, options: [.new]) { wv, _ in
            if !wv.isLoading { done.fulfill() }
        }
        engine.webView.loadHTMLString(html, baseURL: URL(string: "https://example.test/"))
        await fulfillment(of: [done], timeout: 10)
        token.invalidate()
        await engine.waitForSettle(quietMs: 150, timeout: 3)
    }

    private let loginPage = """
    <html><head><title>Sign in · Example</title></head><body>
    <h1>Welcome back</h1>
    <p>Enter your details to continue.</p>
    <form id="f">
      <label for="email">Email</label><input id="email" type="email" placeholder="you@example.com">
      <label for="pw">Password</label><input id="pw" type="password">
      <select id="role"><option>Reader</option><option>Editor</option></select>
      <input type="checkbox" id="remember"><label for="remember">Remember me</label>
      <button type="submit" id="go">Sign in</button>
    </form>
    <a href="/help">Need help?</a>
    <div id="cookie-banner" style="position:fixed;bottom:0;left:0;right:0;background:#eee;padding:8px">
      We use cookies. <button id="accept">Accept all</button>
    </div>
    <script>
      document.getElementById('f').addEventListener('submit', function (e) {
        e.preventDefault();
        document.body.innerHTML = '<h1>Logged in as ' + document.getElementById('email').value + '</h1>';
      });
      document.getElementById('accept').addEventListener('click', function () {
        document.getElementById('cookie-banner').remove();
      });
    </script>
    </body></html>
    """

    func testSnapshotListsInteractiveElementsInReadingOrder() async throws {
        try await load(loginPage)
        let snap = await engine.observe()
        XCTAssertEqual(snap.title, "Sign in · Example")
        let lines = snap.elements.map(\.modelLine)
        XCTAssertTrue(lines.contains { $0.contains("<input type=email placeholder=\"you@example.com\" value=\"\">") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("<input type=password") })
        XCTAssertTrue(lines.contains { $0.contains("<select options=\"Reader|Editor\"") })
        XCTAssertTrue(lines.contains { $0.contains("<checkbox>Remember me</checkbox>") })
        XCTAssertTrue(lines.contains { $0.contains("<button>Sign in</button>") })
        XCTAssertTrue(lines.contains { $0.contains("<link href=\"/help\">Need help?</link>") })
        // Reading order: the email field comes before the button.
        let email = snap.elements.first { $0.inputType == "email" }!.index
        let button = snap.elements.first { $0.text == "Sign in" }!.index
        XCTAssertLessThan(email, button)
        XCTAssertTrue(snap.text.contains("Welcome back"))
        XCTAssertTrue(snap.modelDescription().contains("ELEMENTS ("))
    }

    func testRefsStayStableAcrossSnapshots() async throws {
        try await load(loginPage)
        let a = await engine.observe()
        let b = await engine.observe()
        let refsA = a.elements.map { ($0.text + ($0.placeholder ?? ""), $0.ref) }
        let refsB = b.elements.map { ($0.text + ($0.placeholder ?? ""), $0.ref) }
        XCTAssertEqual(refsA.map(\.0), refsB.map(\.0))
        XCTAssertEqual(refsA.map(\.1), refsB.map(\.1))
    }

    func testTypeSelectCheckAndSubmitByIndex() async throws {
        try await load(loginPage)
        _ = await engine.dismissConsentBanner()
        let snap = await engine.observe()
        let email = snap.elements.first { $0.inputType == "email" }!.index
        let pw = snap.elements.first { $0.inputType == "password" }!.index
        let role = snap.elements.first { $0.kind == "select" }!.index
        let remember = snap.elements.first { $0.kind == "checkbox" }!.index
        let button = snap.elements.first { $0.text == "Sign in" }!.index

        let typedEmail = await engine.typeInto(index: email, text: "jc@example.com", submit: false)
        let typedPw = await engine.typeInto(index: pw, text: "hunter2", submit: false)
        let selected = await engine.selectOption(index: role, value: "editor")
        let checked = await engine.setChecked(index: remember, checked: true)
        XCTAssertTrue(typedEmail.ok)
        XCTAssertTrue(typedPw.ok)
        XCTAssertEqual(selected.detail, "Editor")
        XCTAssertTrue(checked.ok)

        let mid = await engine.observe()
        XCTAssertEqual(mid.element(at: email)?.value, "jc@example.com")
        XCTAssertEqual(mid.element(at: remember)?.checked, true)

        let clicked = await engine.clickElement(index: button)
        XCTAssertTrue(clicked.ok)
        await engine.waitForSettle(quietMs: 150, timeout: 3)
        let after = await engine.observe()
        XCTAssertTrue(after.text.contains("Logged in as jc@example.com"), after.text)
        XCTAssertNotEqual(mid.digest, after.digest)
    }

    func testConsentBannerIsDismissed() async throws {
        try await load(loginPage)
        let label = await engine.dismissConsentBanner()
        XCTAssertEqual(label, "Accept all")
        await engine.waitForSettle(quietMs: 100, timeout: 2)
        let snap = await engine.observe()
        XCTAssertFalse(snap.elements.contains { $0.text == "Accept all" })
        let again = await engine.dismissConsentBanner()
        XCTAssertNil(again)
    }

    func testBlockersDetectLoginAndCaptcha() async throws {
        try await load(loginPage)
        let loginBlockers = await engine.blockers()
        XCTAssertEqual(loginBlockers, [.login])
        try await load("<html><body><h1>Verify you are human</h1><div class=\"g-recaptcha\"></div></body></html>")
        let captchaBlockers = await engine.blockers()
        XCTAssertTrue(captchaBlockers.contains(.captcha))
    }

    func testCoveredElementsAreLeftOut() async throws {
        try await load("""
        <html><body>
        <button id="under">Under the modal</button>
        <div style="position:fixed;inset:0;background:rgba(0,0,0,.5)"><div style="background:#fff;margin:100px;padding:20px">
          <button id="over">Close</button></div></div>
        </body></html>
        """)
        let snap = await engine.observe()
        XCTAssertTrue(snap.elements.contains { $0.text == "Close" })
        XCTAssertFalse(snap.elements.contains { $0.text == "Under the modal" })
    }

    func testScrollReportsEdges() async throws {
        try await load("<html><body style='margin:0'><div style='height:3000px'>tall</div><a href='/end' id='end'>End</a></body></html>")
        let top = await engine.scrollPage(by: -100)
        XCTAssertTrue(top.atTop)
        let snapTop = await engine.observe()
        XCTAssertTrue(snapTop.scrollDescription.contains("pages below"))
        let bottom = await engine.scrollPage(by: 1_000_000)
        XCTAssertTrue(bottom.atBottom)
        let snapBottom = await engine.observe()
        XCTAssertTrue(snapBottom.elements.contains { $0.text == "End" })
    }

    func testMarksAndHighlightDoNotLeakIntoSnapshots() async throws {
        try await load(loginPage)
        _ = await engine.observe()
        await engine.showMarks()
        await engine.highlight(index: 0, label: "Clicking")
        let snap = await engine.observe()
        XCTAssertFalse(snap.text.contains("Clicking"))
        XCTAssertFalse(snap.elements.contains { $0.text == "0" })
        await engine.hideMarks()
        await engine.clearHighlight()
    }

    func testUserInteractionToggle() async throws {
        engine.setUserInteractionEnabled(false)
        XCTAssertFalse(engine.acceptsUserInput)
        #if os(iOS)
        XCTAssertFalse(engine.webView.isUserInteractionEnabled)
        #endif
        engine.setUserInteractionEnabled(true)
        XCTAssertTrue(engine.acceptsUserInput)
    }
}
