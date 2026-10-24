//
//  AgentAction.swift
//  Gepetto
//
//  The actions a model can take, and the forgiving parser that turns a
//  model's reply into one. Small local models get JSON almost right: keys in
//  the wrong case, a stray sentence before the object, a `<tool_call>`
//  wrapper, browser-use style names. The parser accepts all of it rather
//  than failing a step over punctuation.
//

import Foundation

/// One step the agent can take. Element-targeted actions use the index from
/// the latest `PageSnapshot`.
public enum AgentAction: Sendable, Equatable {
    case navigate(url: String)
    case search(query: String)
    case click(index: Int)
    case type(index: Int, text: String, submit: Bool)
    case select(index: Int, value: String)
    case setChecked(index: Int, checked: Bool)
    case scroll(direction: ScrollIntent)
    case scrollTo(index: Int)
    case press(key: String)
    case back
    case wait(seconds: Double)
    /// Read the full page (not just the viewport) and keep going.
    case extract
    /// The agent needs the person: a login, a code, a captcha, a choice.
    case askUser(question: String)
    case done(answer: String, success: Bool)

    public enum ScrollIntent: String, Sendable, CaseIterable {
        case up, down, top, bottom
    }

    public var name: String {
        switch self {
        case .navigate:   return "navigate"
        case .search:     return "search"
        case .click:      return "click"
        case .type:       return "type"
        case .select:     return "select"
        case .setChecked: return "set_checked"
        case .scroll:     return "scroll"
        case .scrollTo:   return "scroll_to"
        case .press:      return "press"
        case .back:       return "back"
        case .wait:       return "wait"
        case .extract:    return "extract"
        case .askUser:    return "ask_user"
        case .done:       return "done"
        }
    }

    /// The element this action targets, if any.
    public var targetIndex: Int? {
        switch self {
        case .click(let i), .type(let i, _, _), .select(let i, _), .setChecked(let i, _), .scrollTo(let i): return i
        default: return nil
        }
    }

    /// SF Symbol for status chips.
    public var symbol: String {
        switch self {
        case .navigate:   return "arrow.up.right.square"
        case .search:     return "magnifyingglass"
        case .click:      return "hand.tap"
        case .type:       return "keyboard"
        case .select:     return "list.bullet"
        case .setChecked: return "checkmark.square"
        case .scroll, .scrollTo: return "arrow.up.and.down"
        case .press:      return "return"
        case .back:       return "arrow.left"
        case .wait:       return "clock"
        case .extract:    return "doc.text.magnifyingglass"
        case .askUser:    return "person.fill.questionmark"
        case .done:       return "checkmark.circle"
        }
    }

    /// Compact text for logs and the model's step history.
    public var compactDescription: String {
        switch self {
        case .navigate(let url):            return "navigate(\(url))"
        case .search(let q):                return "search(\"\(q)\")"
        case .click(let i):                 return "click([\(i)])"
        case .type(let i, let t, let s):    return "type([\(i)], \"\(t.prefix(40))\"\(s ? ", enter" : ""))"
        case .select(let i, let v):         return "select([\(i)], \"\(v)\")"
        case .setChecked(let i, let c):     return "set_checked([\(i)], \(c))"
        case .scroll(let d):                return "scroll(\(d.rawValue))"
        case .scrollTo(let i):              return "scroll_to([\(i)])"
        case .press(let k):                 return "press(\(k))"
        case .back:                         return "back"
        case .wait(let s):                  return "wait(\(s)s)"
        case .extract:                      return "extract"
        case .askUser(let q):               return "ask_user(\"\(q.prefix(60))\")"
        case .done(let a, let ok):          return "done(\(ok ? "success" : "gave up"): \(a.prefix(60)))"
        }
    }

    /// What a person sees while it runs ("Clicking “Sign in” button").
    public func humanLabel(in snapshot: PageSnapshot?) -> String {
        func target(_ i: Int) -> String { snapshot?.element(at: i)?.humanLabel ?? "element \(i)" }
        switch self {
        case .navigate(let url):            return "Opening \(AgentAction.prettyHost(url))"
        case .search(let q):                return "Searching for “\(q.prefix(40))”"
        case .click(let i):                 return "Clicking \(target(i))"
        case .type(let i, let t, _):        return "Typing “\(t.prefix(30))” into \(target(i))"
        case .select(let i, let v):         return "Choosing “\(v.prefix(30))” in \(target(i))"
        case .setChecked(let i, let c):     return (c ? "Checking " : "Unchecking ") + target(i)
        case .scroll(let d):                return "Scrolling \(d.rawValue)"
        case .scrollTo(let i):              return "Scrolling to \(target(i))"
        case .press(let k):                 return "Pressing \(k)"
        case .back:                         return "Going back"
        case .wait(let s):                  return "Waiting \(Int(s.rounded()))s for the page"
        case .extract:                      return "Reading the whole page"
        case .askUser:                      return "Needs you"
        case .done(_, let ok):              return ok ? "Done" : "Stopped"
        }
    }

    static func prettyHost(_ url: String) -> String {
        guard let u = URL(string: url), let host = u.host else { return url }
        return host.replacingOccurrences(of: "www.", with: "")
    }
}

/// A model's reply for one step.
public struct AgentDecision: Sendable, Equatable {
    /// What the model thinks it sees / learned from the last step.
    public var evaluation: String?
    /// Facts it wants to carry forward (what it has found so far).
    public var memory: String?
    /// What it intends to do now and why.
    public var thought: String?
    public var action: AgentAction

    public init(evaluation: String? = nil, memory: String? = nil, thought: String? = nil, action: AgentAction) {
        self.evaluation = evaluation; self.memory = memory; self.thought = thought; self.action = action
    }
}

// MARK: - Parser

public enum AgentOutputParser {

    /// Small models sometimes put the final answer in a JSON object
    /// (`{"title": "…", "poster": "luu"}`). Turn that into lines a person
    /// can read; prose is returned untouched.
    public static func readableAnswer(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return raw }
        func render(_ value: Any) -> String {
            switch value {
            case let text as String: return text
            case let number as NSNumber: return number.stringValue
            case let list as [Any]: return list.map(render).joined(separator: ", ")
            case let dict as [String: Any]:
                return dict.keys.sorted().map { key -> String in
                    let label = key.replacingOccurrences(of: "_", with: " ")
                    return "\(label.prefix(1).uppercased())\(label.dropFirst()): \(render(dict[key] ?? ""))"
                }.joined(separator: "\n")
            default: return "\(value)"
            }
        }
        let rendered = render(object)
        return rendered.isEmpty ? raw : rendered
    }

    public enum Failure: Error, Equatable {
        case noJSON
        case noAction(String)
        case badArguments(String)
    }

    /// Parse the model's text into a decision. Accepts, in order:
    ///  1. `{"thought":…, "action":{"name":"click","index":3}}`
    ///  2. `{"action":"click","index":3}` (flat)
    ///  3. `<tool_call>{"name":"browser","arguments":{"action":"click","index":3}}</tool_call>`
    ///  4. browser-use style `{"action":[{"click_element":{"index":3}}]}`
    ///  5. A bare `done: <answer>` / plain final answer when `allowPlainAnswer`.
    public static func parse(_ text: String, allowPlainAnswer: Bool = true) -> Result<AgentDecision, Failure> {
        let stripped = stripFences(text)
        for candidate in jsonObjects(in: stripped) {
            if let decision = decision(from: candidate) { return .success(decision) }
        }
        // Not JSON. Treat an unambiguous plain answer as `done`.
        let plain = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if allowPlainAnswer, !plain.isEmpty, !plain.contains("{"), plain.count > 2 {
            let lower = plain.lowercased()
            if lower.hasPrefix("done:") || lower.hasPrefix("final answer:") || lower.hasPrefix("answer:") {
                let answer = plain.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
                return .success(AgentDecision(action: .done(answer: String(answer), success: true)))
            }
            return .success(AgentDecision(action: .done(answer: plain, success: true)))
        }
        return .failure(.noJSON)
    }

    /// Pull a partial `"thought": "…"` out of streaming text so the UI can
    /// show the model thinking before the JSON is complete.
    public static func partialThought(in text: String) -> String? {
        for key in ["thought", "next_goal", "reasoning"] {
            guard let r = text.range(of: "\"\(key)\"") else { continue }
            var rest = text[r.upperBound...]
            guard let colon = rest.firstIndex(of: ":") else { continue }
            rest = rest[rest.index(after: colon)...]
            guard let quote = rest.firstIndex(of: "\"") else { continue }
            var out = ""
            var escaped = false
            for ch in rest[rest.index(after: quote)...] {
                if escaped { out.append(ch == "n" ? "\n" : ch); escaped = false; continue }
                if ch == "\\" { escaped = true; continue }
                if ch == "\"" { break }
                out.append(ch)
            }
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: Internals

    static func stripFences(_ text: String) -> String {
        var s = text
        for fence in ["```json", "```JSON", "```"] { s = s.replacingOccurrences(of: fence, with: "\n") }
        s = s.replacingOccurrences(of: "<tool_call>", with: "\n").replacingOccurrences(of: "</tool_call>", with: "\n")
        // Thinking blocks never contain the answer.
        while let open = s.range(of: "<think>"), let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
            s.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return s
    }

    /// Every balanced `{…}` in the text, outermost first, as parsed objects.
    static func jsonObjects(in text: String) -> [[String: Any]] {
        var results: [[String: Any]] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i] == "{" else { i += 1; continue }
            var depth = 0, inString = false, escaped = false
            var j = i
            while j < chars.count {
                let c = chars[j]
                if inString {
                    if escaped { escaped = false }
                    else if c == "\\" { escaped = true }
                    else if c == "\"" { inString = false }
                } else if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1; if depth == 0 { break } }
                j += 1
            }
            if j < chars.count, depth == 0 {
                let candidate = String(chars[i...j])
                if let obj = parseLenient(candidate) { results.append(obj) }
                i = j + 1
            } else {
                i += 1
            }
        }
        return results
    }

    /// JSON with the usual model mistakes repaired: trailing commas, single
    /// quotes, unquoted keys, `True`/`False`.
    static func parseLenient(_ s: String) -> [String: Any]? {
        if let d = s.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { return o }
        var fixed = s
        fixed = fixed.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: #"\bTrue\b"#, with: "true", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: #"\bFalse\b"#, with: "false", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: #"\bNone\b"#, with: "null", options: .regularExpression)
        fixed = fixed.replacingOccurrences(of: #"([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:"#, with: "$1\"$2\":", options: .regularExpression)
        if !fixed.contains("\"") { fixed = fixed.replacingOccurrences(of: "'", with: "\"") }
        if let d = fixed.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { return o }
        return nil
    }

    static func decision(from obj: [String: Any]) -> AgentDecision? {
        let lower = Dictionary(uniqueKeysWithValues: obj.map { ($0.key.lowercased(), $0.value) })
        var evaluation = lower["evaluation"] as? String ?? lower["evaluation_previous_goal"] as? String
        if evaluation?.isEmpty == true { evaluation = nil }
        var memory = lower["memory"] as? String
        if memory?.isEmpty == true { memory = nil }
        var thought = lower["thought"] as? String ?? lower["next_goal"] as? String ?? lower["reasoning"] as? String
        if thought?.isEmpty == true { thought = nil }

        // Legacy tool_call envelope: {"name":"browser","arguments":{…}}
        if let args = lower["arguments"] as? [String: Any], (lower["name"] as? String)?.lowercased() == "browser" || lower["name"] == nil {
            if let a = action(from: args, name: args["action"] as? String) {
                return AgentDecision(evaluation: evaluation, memory: memory, thought: thought, action: a)
            }
        }

        if let actionValue = lower["action"] {
            // {"action": {"name": "click", "index": 3}}
            if let dict = actionValue as? [String: Any] {
                let name = (dict["name"] as? String) ?? (dict["action"] as? String) ?? (dict["type"] as? String)
                if let a = action(from: dict, name: name) {
                    return AgentDecision(evaluation: evaluation, memory: memory, thought: thought, action: a)
                }
                // browser-use style single-key object: {"click_element": {"index": 3}}
                if dict.count == 1, let (k, v) = dict.first, let a = action(from: (v as? [String: Any]) ?? [:], name: k) {
                    return AgentDecision(evaluation: evaluation, memory: memory, thought: thought, action: a)
                }
            }
            // {"action": [{"click_element": {"index": 3}}]}
            if let list = actionValue as? [[String: Any]], let first = list.first, let (k, v) = first.first,
               let a = action(from: (v as? [String: Any]) ?? [:], name: k) {
                return AgentDecision(evaluation: evaluation, memory: memory, thought: thought, action: a)
            }
            // {"action": "click", "index": 3}
            if let name = actionValue as? String, let a = action(from: lower, name: name) {
                return AgentDecision(evaluation: evaluation, memory: memory, thought: thought, action: a)
            }
        }
        // {"click": 3} / {"navigate": "https://…"} / {"done": "answer"}
        for (k, v) in lower {
            let args: [String: Any]
            if let d = v as? [String: Any] { args = d }
            else if let n = v as? Int { args = ["index": n] }
            else if let s = v as? String { args = ["url": s, "query": s, "text": s, "answer": s, "question": s, "direction": s, "key": s] }
            else { continue }
            if let a = action(from: args, name: k) {
                return AgentDecision(evaluation: evaluation, memory: memory, thought: thought, action: a)
            }
        }
        return nil
    }

    static func action(from args: [String: Any], name rawName: String?) -> AgentAction? {
        guard let rawName else { return nil }
        let a = Dictionary(uniqueKeysWithValues: args.map { ($0.key.lowercased(), $0.value) })
        func int(_ keys: String...) -> Int? {
            for k in keys {
                if let n = a[k] as? Int { return n }
                if let d = a[k] as? Double { return Int(d) }
                if let s = a[k] as? String, let n = Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))) { return n }
            }
            return nil
        }
        func str(_ keys: String...) -> String? {
            for k in keys { if let s = a[k] as? String, !s.isEmpty { return s } }
            return nil
        }
        func bool(_ keys: String...) -> Bool? {
            for k in keys {
                if let b = a[k] as? Bool { return b }
                if let s = a[k] as? String { if s.lowercased() == "true" { return true }; if s.lowercased() == "false" { return false } }
            }
            return nil
        }
        let name = rawName.lowercased().replacingOccurrences(of: "-", with: "_")
        switch name {
        case "navigate", "go_to_url", "goto", "open", "open_url", "visit", "load":
            guard let url = str("url", "href", "link", "value") else { return nil }
            return .navigate(url: url)
        case "search", "search_google", "google", "web_search":
            guard let q = str("query", "q", "text", "value") else { return nil }
            return .search(query: q)
        case "click", "click_element", "click_element_by_index", "tap", "press_element", "click_text":
            if let i = int("index", "element", "id", "ref") { return .click(index: i) }
            return nil
        case "type", "input_text", "fill", "enter_text", "type_text", "input", "set_value":
            guard let i = int("index", "element", "id", "ref"), let t = str("text", "value", "input") ?? a["text"] as? String else { return nil }
            let submit = bool("submit", "enter", "press_enter") ?? false
            return .type(index: i, text: t, submit: submit)
        case "select", "select_option", "select_dropdown_option", "choose":
            guard let i = int("index", "element", "id"), let v = str("value", "option", "text") else { return nil }
            return .select(index: i, value: v)
        case "set_checked", "check", "uncheck", "toggle":
            guard let i = int("index", "element", "id") else { return nil }
            let checked = bool("checked", "value") ?? (name != "uncheck")
            return .setChecked(index: i, checked: checked)
        case "scroll", "scroll_down", "scroll_up", "scroll_page":
            if let i = int("index", "element") { return .scrollTo(index: i) }
            let d = str("direction", "value", "to")?.lowercased() ?? (name == "scroll_up" ? "up" : "down")
            return .scroll(direction: AgentAction.ScrollIntent(rawValue: d) ?? .down)
        case "scroll_to", "scroll_to_element", "scroll_into_view":
            guard let i = int("index", "element", "id") else { return nil }
            return .scrollTo(index: i)
        case "press", "press_key", "send_keys", "key", "keypress":
            let k = str("key", "keys", "value") ?? "Enter"
            return .press(key: AgentOutputParser.normalizeKey(k))
        case "back", "go_back", "navigate_back":
            return .back
        case "wait", "sleep", "pause":
            let s = (a["seconds"] as? Double) ?? Double(int("seconds", "ms").map { $0 > 50 ? $0 / 1000 : $0 } ?? 2)
            return .wait(seconds: min(10, max(0.5, s)))
        case "extract", "extract_text", "extract_content", "read", "read_page", "get_text":
            return .extract
        case "ask_user", "ask", "ask_human", "request_user", "need_user", "handoff", "takeover", "request_help":
            return .askUser(question: str("question", "text", "message", "reason") ?? "I need your help with this page.")
        case "done", "finish", "final_answer", "complete", "answer", "stop":
            let text = str("answer", "text", "result", "message", "summary", "final_answer") ?? ""
            let success = bool("success", "ok") ?? true
            return .done(answer: text, success: success)
        default:
            return nil
        }
    }

    static func normalizeKey(_ raw: String) -> String {
        let k = raw.trimmingCharacters(in: .whitespaces)
        switch k.lowercased() {
        case "enter", "return", "\n": return "Enter"
        case "esc", "escape":         return "Escape"
        case "tab":                   return "Tab"
        case "backspace", "delete":   return "Backspace"
        case "space", " ":            return "Space"
        case "down", "arrowdown":     return "ArrowDown"
        case "up", "arrowup":         return "ArrowUp"
        case "left", "arrowleft":     return "ArrowLeft"
        case "right", "arrowright":   return "ArrowRight"
        default:                      return k
        }
    }
}
