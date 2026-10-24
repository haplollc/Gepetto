//
//  FaviconView.swift
//  Gepetto
//
//  The site's own icon in the panel header. Resolved from the page's
//  <link rel="icon"> (falling back to /favicon.ico), fetched once per host
//  and cached for the process. A plain globe stands in until it arrives
//  or when a site has none.
//

import SwiftUI
import WebKit

#if canImport(UIKit)
import UIKit
typealias GepettoImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias GepettoImage = NSImage
#endif

@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()

    /// Icons by host key (see `key(_:)`); each entry was answered for by a
    /// document on that host.
    @Published private(set) var icons: [String: GepettoImage] = [:]
    private var inFlight: Set<String> = []
    private var failed: Set<String> = []

    func icon(forHost host: String) -> GepettoImage? { icons[Self.key(host)] }

    /// Ask the page for its icon link, then fetch it. Safe to call often.
    ///
    /// `WKWebView.url`, and so `engine.currentURL`, moves to the new address
    /// as soon as a navigation starts, before the new document commits. The
    /// script therefore also asks the document which hostname it belongs
    /// to. An answer from another hostname is the previous page: nothing is
    /// cached and nothing is marked failed, and the `isLoading == false`
    /// retry asks the finished document instead.
    func load(for engine: BrowserEngine) {
        guard let url = engine.currentURL, let urlHost = url.host else { return }
        let host = Self.key(urlHost)
        if icons[host] != nil || inFlight.contains(host) || failed.contains(host) { return }
        inFlight.insert(host)
        Task { @MainActor in
            defer { inFlight.remove(host) }
            // location.hostname, not location.host: the latter carries a
            // non-default port, which URL.host never does.
            let js = """
            (function(){var l=document.querySelector("link[rel~='icon'],link[rel='shortcut icon'],link[rel='apple-touch-icon']");
            return JSON.stringify({host: location.hostname || '', href: (l && l.href) ? l.href : ''})})()
            """
            var declared = ""
            var answeredByThisHost = false
            if let raw = (try? await engine.evaluateJavaScript(js)) as? String,
               let data = raw.data(using: .utf8),
               let answer = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                // Another document answered: a navigation is in flight.
                guard Self.key(answer["host"] ?? "") == host else { return }
                answeredByThisHost = true
                declared = answer["href"] ?? ""
            }
            // Still loading with no answer from this host, or a <head> that
            // has not declared an icon yet: wait for the finished document
            // rather than cache a guess under this host.
            if engine.isLoading && (!answeredByThisHost || declared.isEmpty) { return }
            var candidates: [URL] = []
            if !declared.isEmpty, let u = URL(string: declared) { candidates.append(u) }
            let port = url.port.map { ":\($0)" } ?? ""
            let origin = "\(url.scheme ?? "https")://\(urlHost)\(port)"
            if let u = URL(string: origin + "/favicon.ico") { candidates.append(u) }
            if let u = URL(string: origin + "/apple-touch-icon.png") { candidates.append(u) }
            for candidate in candidates {
                if let image = await Self.fetch(candidate) {
                    icons[host] = image
                    return
                }
            }
            failed.insert(host)
        }
    }

    /// Forget an earlier failure for the engine's host and look again.
    func retry(for engine: BrowserEngine) {
        if let host = engine.currentURL?.host { failed.remove(Self.key(host)) }
        load(for: engine)
    }

    /// One spelling for a host, so Foundation's `URL.host` and the page's
    /// `location.hostname` meet: lowercase, without IPv6 brackets.
    private static func key(_ host: String) -> String {
        host.lowercased()
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
    }

    private static func fetch(_ url: URL) async -> GepettoImage? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              data.count > 16, let image = GepettoImage(data: data) else { return nil }
        return image
    }
}

/// The favicon for the engine's current site, or a globe.
struct FaviconView: View {
    @ObservedObject var engine: BrowserEngine
    @ObservedObject private var store = FaviconStore.shared
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let host = engine.currentURL?.host, let image = store.icon(forHost: host) {
                platformImage(image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                Image(systemName: "globe")
                    .font(AgentUI.bodySemibold)
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
        .onAppear { store.load(for: engine) }
        // While a navigation is in flight the document is still the previous
        // page, so a URL change alone is not worth asking; the retry below
        // asks the document that finished. `load` guards this on its own
        // too, for the onAppear path.
        .onChange(of: engine.currentURL) { _ in if !engine.isLoading { store.load(for: engine) } }
        .onChange(of: engine.isLoading) { loading in if !loading { store.retry(for: engine) } }
    }

    private func platformImage(_ image: GepettoImage) -> Image {
        #if canImport(UIKit)
        return Image(uiImage: image)
        #else
        return Image(nsImage: image)
        #endif
    }
}
