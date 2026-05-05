//
//  AutomationScript.swift
//  Gepetto
//
//  Parses a free-form natural-language task into a list of automation
//  stages: each stage is a target URL plus an optional form-fill plan and
//  submit intent. Used by `BrowserAgent.run(...)` to drive multi-step flows
//  deterministically when the task references multiple URLs.
//

import Foundation

/// One stage of a multi-step browser automation: navigate to `url`, then
/// optionally fill a form according to `fillPlan` and submit.
public struct AutomationStage: Sendable, CustomStringConvertible {
    public let url: String
    public let fillPlan: FormFillPlan?
    public init(url: String, fillPlan: FormFillPlan? = nil) {
        self.url = url
        self.fillPlan = fillPlan
    }
    public var description: String {
        "Stage(\(url), \(fillPlan?.description ?? "no-form-fill"))"
    }
}

/// A planned set of (value, field-hint) pairs to type into a page's form,
/// plus whether to submit afterward.
public struct FormFillPlan: Sendable, CustomStringConvertible {
    public struct Pair: Sendable, Equatable {
        public let value: String
        public let fieldHint: String
        public init(value: String, fieldHint: String) {
            self.value = value
            self.fieldHint = fieldHint
        }
    }
    public let values: [Pair]
    public let shouldSubmit: Bool
    public init(values: [Pair], shouldSubmit: Bool) {
        self.values = values
        self.shouldSubmit = shouldSubmit
    }
    public var description: String {
        "FormFillPlan(\(values.map { "\($0.fieldHint)=\"\($0.value)\"" }.joined(separator: ", ")), submit=\(shouldSubmit))"
    }
}

@MainActor
extension BrowserAgent {

    // MARK: - Multi-stage parser

    /// Split a free-form task containing >=2 URLs into ordered stages.
    /// Returns nil for single-URL or no-URL tasks (handled by free-form path).
    func parseAutomationScript(_ task: String) -> [AutomationStage]? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let nsTask = task as NSString
        let range = NSRange(location: 0, length: nsTask.length)
        var urlMatches: [(loc: Int, length: Int, url: String)] = []
        detector.enumerateMatches(in: task, options: [], range: range) { match, _, _ in
            guard let m = match, let url = m.url, let scheme = url.scheme,
                  scheme.hasPrefix("http") else { return }
            urlMatches.append((m.range.location, m.range.length, url.absoluteString))
        }
        guard urlMatches.count >= 2 else { return nil }

        var stages: [AutomationStage] = []
        for (i, m) in urlMatches.enumerated() {
            let segStart = m.loc
            let segEnd = (i + 1 < urlMatches.count) ? urlMatches[i + 1].loc : nsTask.length
            let segment = nsTask.substring(with: NSRange(location: segStart, length: segEnd - segStart))
            let plan = parseFormFillIntent(segment)
            stages.append(AutomationStage(url: m.url, fillPlan: plan))
        }
        return stages
    }

    // MARK: - Form-fill intent parser

    /// Parse natural-language phrasings like:
    ///   - type "X" into the username field
    ///   - and "Y" into the password field
    ///   - fill the email with "Z"
    ///   - search for "Q"
    /// into an ordered FormFillPlan.
    func parseFormFillIntent(_ task: String) -> FormFillPlan? {
        let lower = task.lowercased()
        let submitVerbs = ["click", "submit", "press", "hit", "log in", "login", "search"]
        let shouldSubmit = submitVerbs.contains { lower.contains($0) }

        var pairs: [(String, String)] = []
        let patterns = [
            #"(?:type|enter|use)\s+["“”']([^"”“']+)["“”']\s+(?:into|in|as|for)\s+(?:the\s+)?(\w+)"#,
            #"and\s+["“”']([^"”“']+)["“”']\s+(?:into|in|as|for)\s+(?:the\s+)?(\w+)"#,
            #"fill\s+(?:in\s+)?(?:the\s+)?(\w+)\s+(?:field\s+)?(?:with|using)\s+["“”']([^"”“']+)["“”']"#,
            #"search\s+(?:for\s+)?["“”']([^"”“']+)["“”']"#
        ]

        for (idx, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsTask = task as NSString
            let range = NSRange(location: 0, length: nsTask.length)
            regex.enumerateMatches(in: task, options: [], range: range) { match, _, _ in
                guard let match = match else { return }
                if idx == 3, match.numberOfRanges >= 2 {
                    let value = nsTask.substring(with: match.range(at: 1))
                    pairs.append((value, "search"))
                } else if idx == 2, match.numberOfRanges >= 3 {
                    let field = nsTask.substring(with: match.range(at: 1))
                    let value = nsTask.substring(with: match.range(at: 2))
                    pairs.append((value, field))
                } else if match.numberOfRanges >= 3 {
                    let value = nsTask.substring(with: match.range(at: 1))
                    let field = nsTask.substring(with: match.range(at: 2))
                    pairs.append((value, field))
                }
            }
        }

        guard !pairs.isEmpty else { return nil }
        var seen = Set<String>()
        let uniq = pairs.filter { seen.insert("\($0.0)|\($0.1)").inserted }
        return FormFillPlan(
            values: uniq.map { FormFillPlan.Pair(value: $0.0, fieldHint: $0.1) },
            shouldSubmit: shouldSubmit
        )
    }

    // MARK: - Click / refusal heuristics

    /// True when the user's task asks the agent to click into a content item
    /// from the page we just loaded ("click into the top story", etc.).
    func taskWantsContentClick(_ task: String) -> Bool {
        let lower = task.lowercased()
        let actionVerbs = ["click", "open", "read", "view", "navigate to", "go into", "go to the", "follow", "find the", "look at", "summarize", "summarise"]
        let targets = ["top story", "first story", "first post", "top post", "first article", "top article", "first result", "top result", "the article", "the story", "the post", "the link", "into the", "into a story"]
        return actionVerbs.contains { lower.contains($0) } && targets.contains { lower.contains($0) }
    }

    /// True if the AI's reply looks like a refusal ("I can't browse", "I am
    /// unable", "as a text model", etc.) so the agent loop can intervene.
    func looksLikeRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        let phrases = [
            "i was unable", "i am unable", "i'm unable",
            "i cannot", "i can't", "i would need",
            "i don't have access", "i do not have access",
            "as a text model", "as an ai",
            "would need to click", "would need access"
        ]
        return phrases.contains { lower.contains($0) }
    }
}
