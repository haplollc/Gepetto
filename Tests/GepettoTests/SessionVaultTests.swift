//
//  SessionVaultTests.swift
//  GepettoTests
//
//  The vault against a real Keychain and real WebKit cookie stores. The
//  test runner is unsigned, so it uses the legacy keychain; the app uses
//  the data protection keychain with the same code paths.
//

import XCTest
import WebKit
@testable import Gepetto

@MainActor
final class SessionVaultTests: XCTestCase {
    private func cookie(_ name: String, _ value: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/",
                                .expires: Date().addingTimeInterval(3600), .secure: "TRUE"])!
    }

    func testSignInsSurviveIntoAFreshBrowserAndCanBeForgotten() async throws {
        let name = "test-\(UUID().uuidString.prefix(8))"
        let vault = SessionVault(name: name, keychain: .legacyForTesting)
        defer { vault.forgetAll() }

        // Keep the data stores alive: a cookie store dies with its store.
        let firstStore = WKWebsiteDataStore.nonPersistent()
        let first = firstStore.httpCookieStore
        let unlocked = await vault.restore(into: first)
        XCTAssertTrue(unlocked)
        await first.setCookie(cookie("sid", "abc", domain: ".medium.com"))
        await first.setCookie(cookie("token", "xyz", domain: "accounts.google.com"))
        await vault.save(from: first)
        XCTAssertEqual(vault.sites(), ["google.com", "medium.com"])

        // A new browser (memory-only, empty) gets the same sign-ins back.
        let secondStore = WKWebsiteDataStore.nonPersistent()
        let second = secondStore.httpCookieStore
        let reopened = SessionVault(name: name, keychain: .legacyForTesting)
        let restored = await reopened.restore(into: second)
        XCTAssertTrue(restored)
        let cookies = await second.allCookies()
        XCTAssertEqual(Set(cookies.map(\.name)), ["sid", "token"])
        XCTAssertEqual(cookies.first { $0.name == "sid" }?.value, "abc")

        reopened.forget(site: "google.com")
        XCTAssertEqual(reopened.sites(), ["medium.com"])
        reopened.forgetAll()
        XCTAssertEqual(reopened.sites(), [])
    }

    func testNothingIsSavedUntilTheVaultWasUnlocked() async {
        let vault = SessionVault(name: "test-\(UUID().uuidString.prefix(8))", keychain: .legacyForTesting)
        defer { vault.forgetAll() }
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let store = dataStore.httpCookieStore
        await store.setCookie(cookie("sid", "abc", domain: "example.com"))
        await vault.save(from: store)
        XCTAssertEqual(vault.sites(), [], "a run whose unlock failed must never write over the saved sign-ins")
    }

    func testSignedOutSitesAreRemovedOnSave() async {
        let vault = SessionVault(name: "test-\(UUID().uuidString.prefix(8))", keychain: .legacyForTesting)
        defer { vault.forgetAll() }
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let store = dataStore.httpCookieStore
        _ = await vault.restore(into: store)
        let session = cookie("sid", "abc", domain: "example.com")
        await store.setCookie(session)
        await vault.save(from: store)
        XCTAssertEqual(vault.sites(), ["example.com"])
        await store.deleteCookie(session)
        await vault.save(from: store)
        XCTAssertEqual(vault.sites(), [])
    }

    func testCookiesGroupBySite() {
        XCTAssertEqual(SessionVault.site(of: ".accounts.google.com"), "google.com")
        XCTAssertEqual(SessionVault.site(of: "www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(SessionVault.site(of: "medium.com"), "medium.com")
        XCTAssertEqual(SessionVault.site(of: ".amazon.com"), "amazon.com")
    }
}
