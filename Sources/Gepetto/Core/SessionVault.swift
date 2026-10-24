//
//  SessionVault.swift
//  Gepetto
//
//  Remembers sign-ins between runs without leaving a cookie file on disk.
//  The agent's web view keeps cookies in memory only (a non-persistent
//  WebKit store); the vault saves them to the Keychain, one item per site,
//  and loads them back at the start of the next run.
//
//  The protection is the Keychain's own: items are encrypted by the system
//  with keys held in the Secure Enclave, readable only while the device is
//  unlocked, kept on this device only (never synced to iCloud Keychain or
//  restored from a backup to another device), and, with
//  `requiresUserPresence`, unreadable without Face ID, Touch ID or the
//  passcode. Gepetto implements no cryptography of its own.
//

import Foundation
import Security
import WebKit
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

@MainActor
public final class SessionVault {
    /// Which Keychain the items live in. Apps use `.dataProtection`; the
    /// legacy file-based keychain exists only so unsigned test runners on
    /// macOS (which cannot use the data protection keychain) can exercise
    /// the vault.
    public enum Keychain: Sendable { case dataProtection, legacyForTesting }

    public let name: String
    public private(set) var requiresUserPresence: Bool
    /// True once the saved sign-ins were read for this run. Saving is
    /// refused until then, so a declined Face ID can never overwrite the
    /// saved sessions with an empty browser.
    public private(set) var isUnlocked = false

    private let keychain: Keychain
    #if canImport(LocalAuthentication)
    private var context: LAContext?
    #endif

    public init(name: String = "default", requiresUserPresence: Bool = false, keychain: Keychain = .dataProtection) {
        self.name = name
        self.requiresUserPresence = requiresUserPresence
        self.keychain = keychain
    }

    // MARK: - Run lifecycle

    /// Unlock the vault (Face ID or the passcode when required) and load the
    /// saved cookies into `store`. Returns false when the person declined:
    /// the run then starts signed out and nothing is saved.
    @discardableResult
    public func restore(into store: WKHTTPCookieStore,
                        reason: String = "Use the sign-ins your browser remembers") async -> Bool {
        isUnlocked = false
        guard await authenticate(reason: reason) else { return false }
        let items = readItems(returningData: true)
        let now = Date()
        for item in items {
            guard let data = item.data, let saved = try? JSONDecoder().decode([StoredCookie].self, from: data) else { continue }
            for cookie in saved where (cookie.expires ?? .distantFuture) > now {
                if let http = cookie.httpCookie { await store.setCookie(http) }
            }
        }
        isUnlocked = true
        return true
    }

    /// Save the cookies in `store`, one Keychain item per site. Sites whose
    /// cookies are gone (signed out) are removed. Does nothing until the
    /// vault was unlocked by `restore`.
    public func save(from store: WKHTTPCookieStore) async {
        guard isUnlocked else { return }
        let now = Date()
        let cookies = await store.allCookies().filter { ($0.expiresDate ?? .distantFuture) > now }
        var bySite: [String: [StoredCookie]] = [:]
        for cookie in cookies {
            bySite[Self.site(of: cookie.domain), default: []].append(StoredCookie(cookie))
        }
        let existing = Set(readItems(returningData: false).map(\.site))
        for (site, jar) in bySite {
            guard let data = try? JSONEncoder().encode(jar) else { continue }
            if existing.contains(site) { update(site: site, data: data) } else { add(site: site, data: data) }
        }
        for site in existing.subtracting(bySite.keys) { forget(site: site) }
    }

    // MARK: - Managing saved sign-ins

    /// Sites with saved sign-ins, alphabetically. Reads item names only, so
    /// it never asks for Face ID.
    public func sites() -> [String] {
        readItems(returningData: false).map(\.site).sorted()
    }

    public func forget(site: String) {
        var query = baseQuery()
        query[kSecAttrAccount as String] = site
        SecItemDelete(query as CFDictionary)
    }

    /// Delete every saved sign-in. Nothing remains to recover.
    public func forgetAll() {
        SecItemDelete(baseQuery() as CFDictionary)
        isUnlocked = false
    }

    /// Turn the Face ID requirement on or off. The items are read (asking
    /// for Face ID when they are currently protected) and written back with
    /// the new protection. Returns false when the person declined.
    @discardableResult
    public func setRequiresUserPresence(_ required: Bool,
                                        reason: String = "Change how your saved sign-ins are protected") async -> Bool {
        guard required != requiresUserPresence else { return true }
        guard await authenticate(reason: reason) else { return false }
        let items = readItems(returningData: true)
        requiresUserPresence = required
        SecItemDelete(baseQuery() as CFDictionary)
        for item in items { if let data = item.data { add(site: item.site, data: data) } }
        return true
    }

    // MARK: - Keychain

    private var service: String { "Gepetto.SessionVault.\(name)" }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if keychain == .dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        #if canImport(LocalAuthentication)
        if let context { query[kSecUseAuthenticationContext as String] = context }
        #endif
        return query
    }

    private struct Item { let site: String; let data: Data? }

    /// Every item's site, and its data when asked. Names are listed first
    /// and each item is then read on its own, which every keychain supports
    /// (the macOS file keychain cannot return the data of several items in
    /// one query). The authenticated context is shared, so Face ID is asked
    /// for once.
    private func readItems(returningData: Bool) -> [Item] {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]] else { return [] }
        let sites = rows.compactMap { $0[kSecAttrAccount as String] as? String }
        guard returningData else { return sites.map { Item(site: $0, data: nil) } }
        return sites.map { site in
            var one = baseQuery()
            one[kSecAttrAccount as String] = site
            one[kSecMatchLimit as String] = kSecMatchLimitOne
            one[kSecReturnData as String] = true
            var data: CFTypeRef?
            _ = SecItemCopyMatching(one as CFDictionary, &data)
            return Item(site: site, data: data as? Data)
        }
    }

    private func add(site: String, data: Data) {
        var query = baseQuery()
        query[kSecAttrAccount as String] = site
        query[kSecValueData as String] = data
        query[kSecAttrLabel as String] = "Browser sign-in: \(site)"
        if keychain == .dataProtection {
            if requiresUserPresence,
               let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil) {
                query[kSecAttrAccessControl as String] = access
            } else {
                query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
        }
        SecItemAdd(query as CFDictionary, nil)
    }

    private func update(site: String, data: Data) {
        var query = baseQuery()
        query[kSecAttrAccount as String] = site
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound { add(site: site, data: data) }
    }

    /// Face ID, Touch ID or the passcode, once per run, when the items are
    /// protected. The evaluated context is reused for every Keychain call in
    /// the run so the person is asked once.
    private func authenticate(reason: String) async -> Bool {
        #if canImport(LocalAuthentication)
        guard requiresUserPresence, keychain == .dataProtection else { context = nil; return true }
        let context = LAContext()
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { return false }
        } catch {
            return false
        }
        self.context = context
        return true
        #else
        return true
        #endif
    }

    // MARK: - Sites and cookies

    /// The site a cookie belongs to: its registrable domain, approximately
    /// ("accounts.google.com" → "google.com", "www.bbc.co.uk" → "bbc.co.uk").
    nonisolated static func site(of domain: String) -> String {
        let labels = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".")
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let secondLevel: Set<Substring> = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"]
        let take = (labels[labels.count - 1].count == 2 && secondLevel.contains(labels[labels.count - 2])) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }
}

/// A cookie as it is kept in the vault.
struct StoredCookie: Codable, Equatable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?
    var secure: Bool
    var httpOnly: Bool
    var sameSite: String?

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expires = cookie.expiresDate
        secure = cookie.isSecure
        httpOnly = cookie.isHTTPOnly
        sameSite = cookie.sameSitePolicy?.rawValue
    }

    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path
        ]
        if let expires { properties[.expires] = expires }
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite { properties[.sameSitePolicy] = sameSite }
        return HTTPCookie(properties: properties)
    }
}
