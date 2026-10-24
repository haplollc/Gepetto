//
//  PageSnapshot.swift
//  Gepetto
//
//  What the agent (and the model) knows about the page at one instant: the
//  URL and title, every interactive element in reading order with a short
//  index, the scroll position, and the visible text. Built by
//  `BrowserEngine.observe()` from `PageScript`.
//
//  The model never sees the DOM. It sees one line per element:
//
//      [0]<link href="/login">Sign in</link>
//      [1]<input type=email placeholder="Email" value="">
//      [2]<button>Continue</button>
//
//  and refers to elements by that index. Indices are re-numbered on every
//  snapshot; the `ref` behind each index is stable for the life of the DOM
//  node, so an action is always applied to the element the model saw, even
//  if the page re-rendered in between.
//

import Foundation
import CoreGraphics

public struct PageSnapshot: Sendable, Equatable {

    public struct Element: Sendable, Equatable, Identifiable {
        public let index: Int
        public let ref: String
        /// "link", "button", "input", "textarea", "select", "checkbox",
        /// "radio", "clickable", or an ARIA role.
        public let kind: String
        public let tag: String
        public let text: String
        public let value: String?
        public let inputType: String?
        public let placeholder: String?
        public let options: [String]?
        public let checked: Bool?
        public let href: String?
        /// Viewport-relative frame in CSS pixels.
        public let frame: CGRect
        public let inView: Bool

        public var id: Int { index }

        public init(index: Int, ref: String, kind: String, tag: String, text: String,
                    value: String? = nil, inputType: String? = nil, placeholder: String? = nil,
                    options: [String]? = nil, checked: Bool? = nil, href: String? = nil,
                    frame: CGRect = .zero, inView: Bool = true) {
            self.index = index; self.ref = ref; self.kind = kind; self.tag = tag; self.text = text
            self.value = value; self.inputType = inputType; self.placeholder = placeholder
            self.options = options; self.checked = checked; self.href = href
            self.frame = frame; self.inView = inView
        }

        /// The one line the model reads for this element.
        public var modelLine: String {
            var attrs: [String] = []
            switch kind {
            case "input", "textarea":
                if let t = inputType, !t.isEmpty, t != "text" { attrs.append("type=\(t)") }
                if let p = placeholder, !p.isEmpty { attrs.append("placeholder=\"\(p)\"") }
                attrs.append("value=\"\(value ?? "")\"")
            case "select":
                if let o = options, !o.isEmpty { attrs.append("options=\"\(o.joined(separator: "|"))\"") }
                if let v = value, !v.isEmpty { attrs.append("value=\"\(v)\"") }
            case "checkbox", "radio":
                if checked == true { attrs.append("checked") }
            case "link":
                if let h = href, let short = Element.shortHref(h) { attrs.append("href=\"\(short)\"") }
            default:
                break
            }
            let open = attrs.isEmpty ? kind : "\(kind) \(attrs.joined(separator: " "))"
            let label = text.isEmpty ? (placeholder ?? "") : text
            return "[\(index)]<\(open)>\(label)</\(kind)>"
        }

        /// Keep hrefs readable: same-site links become paths, long query
        /// strings are cut. The agent navigates by index, not by href, so
        /// this is for the model's understanding only.
        static func shortHref(_ href: String) -> String? {
            guard let url = URL(string: href) else { return href.isEmpty ? nil : String(href.prefix(60)) }
            if url.scheme == "javascript" || href.hasPrefix("#") { return nil }
            var s = url.path.isEmpty ? "/" : url.path
            if let q = url.query, !q.isEmpty { s += "?" + String(q.prefix(30)) }
            if s.count > 60 { s = String(s.prefix(59)) + "…" }
            return s
        }

        /// Short human label for status lines ("Sign in button").
        public var humanLabel: String {
            let base = text.isEmpty ? (placeholder ?? kind) : text
            let noun: String
            switch kind {
            case "link":     noun = "link"
            case "button":   noun = "button"
            case "input", "textarea": noun = "field"
            case "select":   noun = "menu"
            default:         noun = ""
            }
            let trimmed = base.count > 40 ? String(base.prefix(39)) + "…" : base
            return noun.isEmpty ? "“\(trimmed)”" : "“\(trimmed)” \(noun)"
        }
    }

    public let url: String
    public let title: String
    public let elements: [Element]
    public let truncated: Bool
    public let scrollY: Double
    public let viewportHeight: Double
    public let totalHeight: Double
    public let text: String
    public let readyState: String
    public let mutations: Int
    public let capturedAt: Date

    public init(url: String, title: String, elements: [Element], truncated: Bool = false,
                scrollY: Double = 0, viewportHeight: Double = 0, totalHeight: Double = 0,
                text: String = "", readyState: String = "complete", mutations: Int = 0,
                capturedAt: Date = Date()) {
        self.url = url; self.title = title; self.elements = elements; self.truncated = truncated
        self.scrollY = scrollY; self.viewportHeight = viewportHeight; self.totalHeight = totalHeight
        self.text = text; self.readyState = readyState; self.mutations = mutations; self.capturedAt = capturedAt
    }

    public static let empty = PageSnapshot(url: "", title: "", elements: [])

    public func element(at index: Int) -> Element? {
        elements.first { $0.index == index }
    }

    /// Where the viewport sits in the page, in screenfuls, for the model.
    public var scrollDescription: String {
        guard totalHeight > viewportHeight + 8, viewportHeight > 0 else { return "the whole page is visible" }
        let above = scrollY / viewportHeight
        let below = max(0, totalHeight - scrollY - viewportHeight) / viewportHeight
        func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
        var s = "\(fmt(above)) pages above, \(fmt(below)) pages below"
        if below > 0.05 { s += " (scroll down to see more)" }
        return s
    }

    /// A cheap fingerprint of what the page looks like. Two snapshots with
    /// the same digest mean an action changed nothing visible.
    public var digest: String {
        var hasher = Hasher()
        hasher.combine(url)
        hasher.combine(title)
        for e in elements { hasher.combine(e.modelLine) }
        hasher.combine(text.prefix(400))
        hasher.combine(Int(scrollY / 50))
        return String(hasher.finalize(), radix: 16)
    }

    /// The observation block the model reads each step. Elements whose
    /// `ref` is not in `previousRefs` are marked `*`: new since the last step,
    /// which is usually where the model should look after an action.
    public func modelDescription(maxTextChars: Int = 1200, maxElements: Int = 60, previousRefs: Set<String>? = nil) -> String {
        var lines: [String] = []
        lines.append("URL: \(url)")
        lines.append("TITLE: \(title.isEmpty ? "(none)" : title)")
        lines.append("SCROLL: \(scrollDescription)")
        let shown = elements.prefix(maxElements)
        if shown.isEmpty {
            lines.append("ELEMENTS: none visible. The page may still be loading: wait, or scroll.")
        } else {
            if shown.count < 4 { lines.append("(Few elements: the page may still be loading.)") }
            let more = truncated || elements.count > maxElements
            let newCount = previousRefs.map { prev in shown.filter { !prev.contains($0.ref) }.count }
            var header = "ELEMENTS (\(shown.count)"
            if more { header += ", more below the fold" }
            if let n = newCount, n > 0, n < shown.count { header += ", * = new since your last action" }
            header += "):"
            lines.append(header)
            for e in shown {
                let isNew = previousRefs.map { !$0.contains(e.ref) } ?? false
                lines.append((isNew && newCount.map { $0 < shown.count } == true ? "*" : "") + e.modelLine)
            }
        }
        if !text.isEmpty {
            let t = text.count > maxTextChars ? String(text.prefix(maxTextChars - 1)) + "…" : text
            lines.append("VISIBLE TEXT: \(t)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Decoding from the page script

    static func from(json: Any?) -> PageSnapshot? {
        guard let dict = json as? [String: Any] else { return nil }
        let rawElements = dict["elements"] as? [[String: Any]] ?? []
        let elements: [Element] = rawElements.compactMap { e in
            guard let index = e["index"] as? Int, let ref = e["ref"] as? String else { return nil }
            let box = e["box"] as? [String: Any] ?? [:]
            func num(_ k: String) -> CGFloat { CGFloat((box[k] as? NSNumber)?.doubleValue ?? 0) }
            return Element(
                index: index, ref: ref,
                kind: e["kind"] as? String ?? "clickable",
                tag: e["tag"] as? String ?? "",
                text: e["text"] as? String ?? "",
                value: e["value"] as? String,
                inputType: e["inputType"] as? String,
                placeholder: e["placeholder"] as? String,
                options: e["options"] as? [String],
                checked: e["checked"] as? Bool,
                href: e["href"] as? String,
                frame: CGRect(x: num("x"), y: num("y"), width: num("w"), height: num("h")),
                inView: e["inView"] as? Bool ?? true
            )
        }
        let scroll = dict["scroll"] as? [String: Any] ?? [:]
        func dbl(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
        return PageSnapshot(
            url: dict["url"] as? String ?? "",
            title: dict["title"] as? String ?? "",
            elements: elements,
            truncated: dict["truncated"] as? Bool ?? false,
            scrollY: dbl(scroll, "y"),
            viewportHeight: dbl(scroll, "viewport"),
            totalHeight: dbl(scroll, "total"),
            text: dict["text"] as? String ?? "",
            readyState: dict["readyState"] as? String ?? "",
            mutations: (dict["mutations"] as? NSNumber)?.intValue ?? 0
        )
    }
}
