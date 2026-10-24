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
        // Layout and hit-testing need an on-screen window; keep it invisible
        // so the test run never flashes anything on the person's screen.
        window.alphaValue = 0
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

    /// Evaluate in the page script's private world, where PageObserver runs.
    /// (`engine.evaluateJavaScript` is the page's own world.)
    private func inGepettoWorld(_ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            engine.webView.evaluateJavaScript(js, in: nil, in: BrowserEngine.contentWorld) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
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
        // A rendered widget on screen (srcdoc stands in for Google's frame, so
        // the test needs no network). An empty .g-recaptcha div is only a
        // marker and must not count.
        try await load("""
        <html><body><h1>Verify you are human</h1>
        <div class="g-recaptcha" data-sitekey="test"><iframe title="reCAPTCHA" style="width:304px;height:78px;border:0" srcdoc="<p>checkbox</p>"></iframe></div>
        </body></html>
        """)
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

    // MARK: - Secrets and forms

    func testSecretFieldValuesNeverReachTheSnapshot() async throws {
        try await load("""
        <html><body><form>
          <label for="email">Email</label><input id="email" type="email">
          <label for="pw">Password</label><input id="pw" type="password">
          <label for="cc">Card</label><input id="cc" autocomplete="cc-number">
          <button type="submit">Pay</button>
        </form></body></html>
        """)
        let empty = await engine.observe()
        let pw = try XCTUnwrap(empty.elements.first { $0.inputType == "password" })
        let card = try XCTUnwrap(empty.elements.first { $0.text == "Card" })
        XCTAssertTrue(pw.isSecret)
        XCTAssertTrue(card.isSecret)
        XCTAssertFalse(pw.isFilled)
        XCTAssertTrue(pw.modelLine.contains("value=\"\""), pw.modelLine)

        let typed = await engine.typeInto(index: pw.index, text: "hunter2", submit: false)
        XCTAssertTrue(typed.ok)
        XCTAssertFalse(typed.detail.contains("hunter2"))
        _ = await engine.typeInto(index: card.index, text: "4242424242424242", submit: false)

        let snap = await engine.observe()
        let description = snap.modelDescription()
        for secret in ["hunter2", "4242"] {
            XCTAssertFalse(description.contains(secret), description)
            XCTAssertFalse(snap.text.contains(secret), snap.text)
            XCTAssertFalse(snap.elements.contains { $0.modelLine.contains(secret) || ($0.value ?? "").contains(secret) })
        }
        let filled = try XCTUnwrap(snap.elements.first { $0.inputType == "password" })
        XCTAssertTrue(filled.isFilled)
        XCTAssertTrue(filled.modelLine.contains("value=\"(filled)\""), filled.modelLine)
        // The page itself still holds the password; only the snapshot leaves it out.
        let inPage = (try await engine.evaluateJavaScript("document.getElementById('pw').value")) as? String
        XCTAssertEqual(inPage, "hunter2")
    }

    func testFormFieldsCarryTheirSubmitLabel() async throws {
        try await load(loginPage)
        let login = await engine.observe()
        let email = try XCTUnwrap(login.elements.first { $0.inputType == "email" })
        XCTAssertEqual(email.submitLabel, "Sign in")
        XCTAssertFalse(email.modelLine.contains("Sign in"), email.modelLine)

        try await load("""
        <html><body>
        <form><textarea name="body" aria-label="Comment"></textarea>
          <button type="button">Preview</button>
          <input type="submit" name="commit" value="Post comment"></form>
        <input aria-label="Outside">
        </body></html>
        """)
        let snap = await engine.observe()
        let comment = try XCTUnwrap(snap.elements.first { $0.text == "Comment" })
        XCTAssertEqual(comment.submitLabel, "Post comment")
        let outside = try XCTUnwrap(snap.elements.first { $0.text == "Outside" })
        XCTAssertNil(outside.submitLabel)
    }

    func testButtonInputsAreLabelledByTheirValue() async throws {
        try await load("""
        <html><body><form>
        <input aria-label="Username">
        <input type="submit" value="login">
        <input type="submit" name="commit" value="Post comment">
        <input type="button" value="Cancel">
        <input type="reset">
        <input type="submit" name="go">
        <input type="image" alt="Search" style="width:40px;height:20px" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7">
        </form></body></html>
        """)
        let snap = await engine.observe()
        let lines = snap.elements.map(\.modelLine)
        for caption in ["login", "Post comment", "Cancel", "Reset", "Submit", "Search"] {
            XCTAssertTrue(lines.contains { $0.hasSuffix("<button>\(caption)</button>") }, "\(caption) missing from \(lines)")
        }
        XCTAssertFalse(lines.contains { $0.contains("commit") || $0.contains("<button></button>") }, "\(lines)")
    }

    // MARK: - Blockers and consent

    func testBlockersCountOnlyWhatIsOnScreen() async throws {
        // Markers that stay on a page whatever the person does: a sign-in
        // link, prose about codes, a hidden login form, a captcha setting in a
        // script and an empty response field, the reCAPTCHA notice, a 0x0
        // Stripe frame.
        try await load("""
        <html><head><script>window.siteConfig = { captcha: false };</script></head><body>
        <a href="/login">Sign in</a>
        <p>Turn on two-factor authentication to get a verification code from your authenticator app.</p>
        <form id="hidden-login" style="display:none"><input type="password" name="password"></form>
        <textarea name="g-recaptcha-response" style="display:none"></textarea>
        <iframe name="__privateStripeController1" style="width:0;height:0;border:0"></iframe>
        <footer>This site is protected by reCAPTCHA and the Google Privacy Policy.</footer>
        </body></html>
        """)
        let markersOnly = await engine.blockers()
        XCTAssertEqual(markersOnly, [])

        // The same password field, once on screen, is a sign-in wall.
        _ = try await engine.evaluateJavaScript("document.getElementById('hidden-login').style.display = 'block'; true")
        let visible = await engine.blockers()
        XCTAssertEqual(visible, [.login])
    }

    func testStoreFramesThatMentionCardsAreNotPaymentForms() async throws {
        // A product page: an ad frame and a credit card offer, both on screen.
        try await load("""
        <html><body>
        <iframe name="ad-creditcard-offer" src="about:blank#creditcard-banner" style="width:300px;height:120px;border:0"></iframe>
        <iframe title="Amazon Visa card offer" style="width:300px;height:80px;border:0"></iframe>
        </body></html>
        """)
        let offers = await engine.blockers()
        XCTAssertEqual(offers, [])

        // A hosted card field, as Stripe names it for screen readers.
        _ = try await engine.evaluateJavaScript("""
        var f = document.createElement('iframe'); f.title = 'Secure card number input frame';
        f.style.cssText = 'width:300px;height:40px;border:0'; document.body.appendChild(f); true
        """)
        let field = await engine.blockers()
        XCTAssertEqual(field, [.payment])
    }

    func testSolvedCaptchaNoLongerBlocks() async throws {
        try await load("""
        <html><body><form>
        <div class="g-recaptcha" data-sitekey="test">
          <iframe title="reCAPTCHA" style="width:304px;height:78px;border:0" srcdoc="<p>checkbox</p>"></iframe>
          <textarea name="g-recaptcha-response" style="display:none"></textarea>
        </div>
        </form>
        <div class="grecaptcha-badge" style="position:fixed;bottom:14px;right:0;width:256px;height:60px">
          <iframe title="reCAPTCHA" style="width:256px;height:60px;border:0" srcdoc="<p>badge</p>"></iframe>
        </div>
        </body></html>
        """)
        let unsolved = await engine.blockers()
        XCTAssertEqual(unsolved, [.captcha])
        // Ticking the box fills the response field; the badge alone is not a captcha.
        _ = try await engine.evaluateJavaScript("document.querySelector('[name=g-recaptcha-response]').value = 'token'; true")
        let solved = await engine.blockers()
        XCTAssertEqual(solved, [])
    }

    func testConsentDismissalLeavesOtherDialogsAlone() async throws {
        try await load("""
        <html><body>
        <div role="dialog" aria-modal="true" style="position:fixed;top:10px;left:10px;width:360px;background:#fff">
          <p>Your card ending 4242 will be charged $12.99.</p>
          <button onclick="window.__clicks.push('pay')">Continue</button>
          <button onclick="window.__clicks.push('cancel')">Cancel</button>
        </div>
        <div role="dialog" style="position:fixed;top:120px;left:10px;width:360px;background:#fff">
          <p>By continuing you consent to our Terms of Service and Privacy Policy.</p>
          <button onclick="window.__clicks.push('terms')">I agree</button>
        </div>
        <div role="dialog" style="position:fixed;top:220px;left:10px;width:360px;background:#fff">
          <p>Sign in to continue. We use cookies to keep you signed in.</p>
          <input type="email" aria-label="Email">
          <button onclick="window.__clicks.push('login')">Continue</button>
        </div>
        <div class="promo-banner" style="position:fixed;top:340px;left:10px;width:360px;background:#eee">
          Spring sale ends soon. <button onclick="window.__clicks.push('promo')">OK</button>
        </div>
        <div id="cookie-notice" style="position:fixed;bottom:0;left:0;right:0;background:#eee">
          We use cookies to improve your experience.
          <button onclick="window.__clicks.push('reject')">Reject all</button>
          <button onclick="window.__clicks.push('accept'); this.parentNode.remove()">Accept all</button>
        </div>
        <script>window.__clicks = [];</script>
        </body></html>
        """)
        // Only the cookie notice is a consent host, and Accept all wins there.
        let first = await engine.dismissConsentBanner()
        XCTAssertEqual(first, "Accept all")
        let second = await engine.dismissConsentBanner()
        XCTAssertNil(second)
        let clicks = (try await engine.evaluateJavaScript("window.__clicks.join(',')")) as? String
        XCTAssertEqual(clicks, "accept")
    }

    // MARK: - Shadow DOM, frames, and element detection

    func testShadowRootControlsAreListedReadAndClickable() async throws {
        try await load("""
        <html><body>
        <div id="host"></div>
        <script>
          var root = document.getElementById('host').attachShadow({ mode: 'open' });
          root.innerHTML = '<p>Inside the component</p><label for="q">Query</label><input id="q"><button id="b">Shadow button</button>';
          root.getElementById('b').addEventListener('click', function () { document.title = 'clicked'; });
        </script>
        </body></html>
        """)
        let snap = await engine.observe()
        let lines = snap.elements.map(\.modelLine)
        let button = try XCTUnwrap(snap.elements.first { $0.text == "Shadow button" }, "\(lines)")
        XCTAssertTrue(snap.elements.contains { $0.text == "Query" }, "\(lines)")
        XCTAssertTrue(snap.text.contains("Inside the component"), snap.text)
        let clicked = await engine.clickElement(index: button.index)
        XCTAssertTrue(clicked.ok)
        let title = (try await engine.evaluateJavaScript("document.title")) as? String
        XCTAssertEqual(title, "clicked")
    }

    func testSameOriginFramesAreReadInPlace() async throws {
        try await load("""
        <html><body>
        <p>Before the frame</p>
        <iframe style="width:400px;height:120px;border:0" srcdoc="<p>Invalid email address</p><input aria-label='Frame email'>"></iframe>
        <p>After the frame</p>
        </body></html>
        """)
        let snap = await engine.observe()
        let before = try XCTUnwrap(snap.text.range(of: "Before the frame"), snap.text)
        let inside = try XCTUnwrap(snap.text.range(of: "Invalid email address"), snap.text)
        let after = try XCTUnwrap(snap.text.range(of: "After the frame"), snap.text)
        XCTAssertLessThan(before.lowerBound, inside.lowerBound)
        XCTAssertLessThan(inside.lowerBound, after.lowerBound)
        XCTAssertTrue(snap.elements.contains { $0.text == "Frame email" }, "\(snap.elements.map(\.modelLine))")
    }

    func testClippedControlsAreLeftOutButLabelledOnesStay() async throws {
        // A collapsed menu's links are laid out but never painted. A wrapped
        // inline link and a visually hidden checkbox (reached through its
        // label, on a line made tall by an image) are still usable.
        try await load("""
        <html><head><style>.sr { position:absolute; width:1px; height:1px; overflow:hidden; clip:rect(0,0,0,0); }</style></head>
        <body style="margin:0">
        <p style="width:300px">Some text that runs on and then <a href="/long">a long link that wraps across two lines of the paragraph</a> and more after it.</p>
        <nav style="max-height:0;overflow:hidden"><a href="/m1" style="display:block;height:40px">Menu one</a><a href="/m2" style="display:block;height:40px">Menu two</a></nav>
        <label><input type="checkbox" class="sr"><span>Notify me</span></label>
        <img alt="" width="30" height="30" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7">
        </body></html>
        """)
        let snap = await engine.observe()
        let lines = snap.elements.map(\.modelLine)
        XCTAssertFalse(snap.elements.contains { $0.text == "Menu one" || $0.text == "Menu two" }, "\(lines)")
        XCTAssertTrue(snap.elements.contains { $0.kind == "link" && $0.text.hasPrefix("a long link") }, "\(lines)")
        XCTAssertTrue(snap.elements.contains { $0.kind == "checkbox" && $0.text == "Notify me" }, "\(lines)")
    }

    func testPointerCursorChildrenAreNotSeparateElements() async throws {
        try await load("""
        <html><head><style>button, .card, .row { cursor: pointer; }</style></head><body>
        <button><svg width="12" height="12"><path d="M0 0h12v12H0z"></path></svg><span>Sign in</span></button>
        <div class="card"><span>Card title</span> <span>Card body</span> <span>More</span> <span>Words</span></div>
        <div class="row"><span>Open message</span> <a href="/star">Star</a></div>
        </body></html>
        """)
        let snap = await engine.observe()
        let lines = snap.elements.map(\.modelLine)
        XCTAssertEqual(snap.elements.filter { $0.text.contains("Sign in") }.count, 1, "\(lines)")
        XCTAssertEqual(snap.elements.filter { $0.text.contains("Card title") }.count, 1, "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasSuffix("<clickable></clickable>") }, "\(lines)")
        // A pointer row that wraps a link is not listed itself, so its text stands in for it.
        XCTAssertTrue(snap.elements.contains { $0.text == "Open message" }, "\(lines)")
        XCTAssertTrue(snap.elements.contains { $0.text == "Star" }, "\(lines)")
    }

    func testAriaTogglesReportAndRespectTheirState() async throws {
        try await load("""
        <html><body>
        <button role="switch" aria-checked="true" onclick="this.setAttribute('aria-checked', String(this.getAttribute('aria-checked') !== 'true'))">Email notifications</button>
        <div role="checkbox" aria-checked="false" tabindex="0" onclick="this.setAttribute('aria-checked', String(this.getAttribute('aria-checked') !== 'true'))">Subscribe</div>
        </body></html>
        """)
        let snap = await engine.observe()
        let toggle = try XCTUnwrap(snap.elements.first { $0.text == "Email notifications" })
        let box = try XCTUnwrap(snap.elements.first { $0.text == "Subscribe" })
        XCTAssertEqual(toggle.kind, "switch")
        XCTAssertEqual(toggle.checked, true)
        XCTAssertTrue(toggle.modelLine.contains("<switch checked>"), toggle.modelLine)
        XCTAssertEqual(box.checked, false)

        // Already on: nothing is clicked, so it stays on.
        let keep = await engine.setChecked(index: toggle.index, checked: true)
        XCTAssertTrue(keep.ok)
        XCTAssertEqual(keep.detail, "already checked")
        _ = await engine.setChecked(index: box.index, checked: true)
        let after = await engine.observe()
        XCTAssertEqual(after.elements.first { $0.text == "Email notifications" }?.checked, true)
        XCTAssertEqual(after.elements.first { $0.text == "Subscribe" }?.checked, true)
    }

    func testSvgIconButtonCanBeClicked() async throws {
        try await load("""
        <html><body>
        <svg role="button" tabindex="0" aria-label="Close" width="24" height="24" onclick="document.title = 'closed'"><rect width="24" height="24"></rect></svg>
        </body></html>
        """)
        let snap = await engine.observe()
        let close = try XCTUnwrap(snap.elements.first { $0.text == "Close" }, "\(snap.elements.map(\.modelLine))")
        let result = await engine.clickElement(index: close.index)
        XCTAssertTrue(result.ok, result.error ?? "")
        let title = (try await engine.evaluateJavaScript("document.title")) as? String
        XCTAssertEqual(title, "closed")
    }

    // MARK: - Refs, isolation, settle, keys, scrolling

    func testRefsNeverRepeatAcrossDocuments() async throws {
        try await load("<html><body><a href='/a'>First</a><button>One</button></body></html>")
        let first = await engine.observe()
        try await load("<html><body><a href='/b'>Second</a><button>Two</button></body></html>")
        let second = await engine.observe()
        XCTAssertEqual(first.elements.count, 2)
        XCTAssertEqual(second.elements.count, 2)
        XCTAssertTrue(Set(first.elements.map(\.ref)).isDisjoint(with: second.elements.map(\.ref)),
                      "\(first.elements.map(\.ref)) \(second.elements.map(\.ref))")
    }

    func testPageScriptsCannotReplaceTheObserver() async throws {
        // A page that pre-defines the namespace, as a phishing page would, to
        // report another site's URL and no blockers.
        try await load("""
        <html><head><title>Not Google</title><script>
        window.__gepetto = { version: 2,
          snapshot: function () { return { url: 'https://accounts.google.com/signin', title: 'Sign in', elements: [], text: '' }; },
          blockers: function () { return []; } };
        </script></head><body><form><input type="password" aria-label="Password"></form></body></html>
        """)
        let snap = await engine.observe()
        XCTAssertEqual(snap.url, "https://example.test/")
        XCTAssertEqual(snap.title, "Not Google")
        XCTAssertTrue(snap.elements.contains { $0.inputType == "password" }, "\(snap.elements.map(\.modelLine))")
        let blockers = await engine.blockers()
        XCTAssertEqual(blockers, [.login])
        // Ours lives in the private world; the page's own object is untouched.
        let ours = (try await inGepettoWorld("typeof window.__gepetto.click")) as? String
        XCTAssertEqual(ours, "function")
        let pageSees = (try await engine.evaluateJavaScript("typeof window.__gepetto.click")) as? String
        XCTAssertEqual(pageSees, "undefined")
    }

    func testOwnWritesDoNotCountAsPageMutations() async throws {
        try await load(loginPage)
        let before = (try await inGepettoWorld("window.__gepetto.mutationCount()")) as? Int
        _ = await engine.observe()      // sets data-gep-ref on every listed element
        await engine.showMarks()        // inserts the overlay and its badges
        await engine.hideMarks()
        let after = (try await inGepettoWorld("window.__gepetto.mutationCount()")) as? Int
        XCTAssertNotNil(before)
        XCTAssertEqual(before, after)
    }

    func testPressKeyUsesTheFocusedElementInFramesAndTabMovesFocus() async throws {
        try await load("""
        <html><body>
        <input aria-label="First"><input aria-label="Second">
        <iframe id="f" style="width:400px;height:120px;border:0"></iframe>
        <script>
          var d = document.getElementById('f').contentDocument;
          d.open(); d.write('<form id="g"><input aria-label="Code"><button>Send</button></form>'); d.close();
          d.getElementById('g').addEventListener('submit', function (e) { e.preventDefault(); document.title = 'sent'; });
        </script>
        </body></html>
        """)
        let snap = await engine.observe()
        let lines = snap.elements.map(\.modelLine)
        let first = try XCTUnwrap(snap.elements.first { $0.text == "First" }, "\(lines)")
        let code = try XCTUnwrap(snap.elements.first { $0.text == "Code" }, "\(lines)")

        _ = await engine.typeInto(index: first.index, text: "a", submit: false)
        let tab = await engine.pressKey("Tab")
        XCTAssertTrue(tab.ok)
        let focused = (try await engine.evaluateJavaScript("document.activeElement.getAttribute('aria-label')")) as? String
        XCTAssertEqual(focused, "Second")

        // Focus inside a frame: Enter goes to that field and submits its form.
        _ = await engine.typeInto(index: code.index, text: "123456", submit: false)
        let enter = await engine.pressKey("Enter")
        XCTAssertTrue(enter.ok)
        XCTAssertEqual(enter.detail, "input")
        let title = (try await engine.evaluateJavaScript("document.title")) as? String
        XCTAssertEqual(title, "sent")
    }

    func testAgentTypingKeepsTheKeyboardDownUntilTheFieldLosesFocus() async throws {
        try await load("""
        <html><body><input aria-label="Email" inputmode="email"><input aria-label="Name"></body></html>
        """)
        let snap = await engine.observe()
        let email = try XCTUnwrap(snap.elements.first { $0.text == "Email" })
        _ = await engine.typeInto(index: email.index, text: "a@b.co", submit: false)
        let query = "document.querySelector('[aria-label=Email]').getAttribute('inputmode')"
        let during = (try await engine.evaluateJavaScript(query)) as? String
        XCTAssertEqual(during, "none", "no on-screen keyboard while the agent types")
        let focused = (try await engine.evaluateJavaScript("document.activeElement.getAttribute('aria-label')")) as? String
        XCTAssertEqual(focused, "Email", "the field keeps focus so Enter can follow")
        _ = try await engine.evaluateJavaScript("document.activeElement.blur(); true")
        let after = (try await engine.evaluateJavaScript(query)) as? String
        XCTAssertEqual(after, "email", "the page's own inputmode comes back on blur")
    }

    func testInnerContainerScrollReportsBothEdges() async throws {
        // An app layout: the window cannot scroll, a full-height panel does.
        try await load("""
        <html><body style="margin:0;height:100vh;overflow:hidden">
        <div style="height:100%;overflow:auto"><div style="height:3000px">long list</div></div>
        </body></html>
        """)
        let down = await engine.scrollPage(by: 400)
        XCTAssertFalse(down.atTop)
        XCTAssertFalse(down.atBottom)
        let top = await engine.scrollPage(by: -1_000_000)
        XCTAssertTrue(top.atTop)
        XCTAssertFalse(top.atBottom)
        let bottom = await engine.scrollPage(by: 1_000_000)
        XCTAssertTrue(bottom.atBottom)
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
