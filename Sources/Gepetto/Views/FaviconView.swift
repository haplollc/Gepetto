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

    @Published private(set) var icons: [String: GepettoImage] = [:]
    private var inFlight: Set<String> = []
    private var failed: Set<String> = []

    func icon(forHost host: String) -> GepettoImage? { icons[host] }

    /// Ask the page for its icon link, then fetch it. Safe to call often.
    func load(for engine: BrowserEngine) {
        guard let url = engine.currentURL, let host = url.host else { return }
        if icons[host] != nil || inFlight.contains(host) || failed.contains(host) { return }
        inFlight.insert(host)
        Task { @MainActor in
            defer { inFlight.remove(host) }
            let js = """
            (function(){var l=document.querySelector("link[rel~='icon'],link[rel='shortcut icon'],link[rel='apple-touch-icon']");
            return l && l.href ? l.href : ''})()
            """
            let declared = (try? await engine.evaluateJavaScript(js)) as? String ?? ""
            var candidates: [URL] = []
            if let u = URL(string: declared), !declared.isEmpty { candidates.append(u) }
            if let origin = URL(string: "\(url.scheme ?? "https")://\(host)/favicon.ico") { candidates.append(origin) }
            for candidate in candidates {
                if let image = await Self.fetch(candidate) {
                    icons[host] = image
                    return
                }
            }
            failed.insert(host)
        }
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
        .onChange(of: engine.currentURL) { _ in store.load(for: engine) }
        .onChange(of: engine.isLoading) { loading in if !loading { store.load(for: engine) } }
    }

    private func platformImage(_ image: GepettoImage) -> Image {
        #if canImport(UIKit)
        return Image(uiImage: image)
        #else
        return Image(nsImage: image)
        #endif
    }
}
