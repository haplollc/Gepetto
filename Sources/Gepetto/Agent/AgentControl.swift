//
//  AgentControl.swift
//  Gepetto
//
//  Who is driving, and the rules for handing the wheel over. The agent is
//  one of: running, paused, waiting for the person (to take over the page,
//  to approve something, or to answer a question), or finished. A person
//  can take over at any moment; the agent re-reads the page when control
//  comes back and is told what changed while it was away.
//

import Foundation

// MARK: - Control state

/// Why the agent stepped aside for the person.
public enum TakeoverReason: Sendable, Equatable {
    /// The person tapped "Take over".
    case userInitiated
    /// The page needs something only a person has (login, code, captcha, payment).
    case blocker(PageBlocker)
    /// The model asked for help in its own words.
    case agentAsked(question: String)

    public var title: String {
        switch self {
        case .userInitiated:          return "You're in control"
        case .blocker(let b):         return b.title
        case .agentAsked:             return "The agent needs you"
        }
    }

    public var message: String {
        switch self {
        case .userInitiated:          return "Browse, sign in, or fix anything. Hand control back when you're ready."
        case .blocker(let b):         return b.message
        case .agentAsked(let q):      return q
        }
    }
}

/// Something the agent is waiting on the person for.
public enum UserRequest: Sendable, Equatable {
    /// The person is driving the page.
    case takeover(TakeoverReason)
    /// The agent wants to do something that should be approved first.
    case confirm(action: AgentAction, summary: String, category: SensitiveActionCategory)
    /// The agent asked a question and wants a text answer.
    case question(String)
}

public enum AgentControlState: Sendable, Equatable {
    case idle
    case running
    case paused
    case waitingForUser(UserRequest)
    case stopping
    case finished(success: Bool)

    public var isWaitingForUser: Bool {
        if case .waitingForUser = self { return true }
        return false
    }

    public var isHumanDriving: Bool {
        if case .waitingForUser(.takeover) = self { return true }
        return false
    }

    public var isActive: Bool {
        switch self {
        case .running, .paused, .waitingForUser, .stopping: return true
        case .idle, .finished: return false
        }
    }
}

// MARK: - Sensitive actions

/// Actions worth a second look before the agent does them on someone's
/// behalf: money, messages, destructive changes, and account changes.
public enum SensitiveActionCategory: String, Sendable, CaseIterable {
    case purchase
    case send
    case delete
    case account

    public var title: String {
        switch self {
        case .purchase: return "Purchase"
        case .send:     return "Send or post"
        case .delete:   return "Delete"
        case .account:  return "Account change"
        }
    }

    static let patterns: [SensitiveActionCategory: [String]] = [
        .purchase: ["buy", "purchase", "place order", "place your order", "pay", "checkout", "check out", "confirm order",
                    "complete order", "subscribe", "add to cart", "book now", "reserve", "donate", "upgrade plan"],
        .send:     ["send", "post", "publish", "submit", "reply", "tweet", "comment", "share", "message", "apply"],
        .delete:   ["delete", "remove", "unsubscribe", "cancel subscription", "deactivate", "clear all", "discard", "erase"],
        .account:  ["change password", "reset password", "update email", "close account", "sign out", "log out", "transfer"]
    ]

    /// The category a button label falls into, if any. `pageText` lets a
    /// generic "Confirm" / "Continue" next to a price count as a purchase.
    public static func classify(label: String, pageText: String? = nil) -> SensitiveActionCategory? {
        let l = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, l.count < 60 else { return nil }
        if ["reject all", "only necessary", "necessary only", "decline"].contains(l) { return nil } // cookie banners
        for (category, words) in patterns {
            for w in words where l == w || l.hasPrefix(w + " ") || l.hasSuffix(" " + w) || l.contains(" \(w) ") || l == w + "!" {
                return category
            }
        }
        if let text = pageText, ["confirm", "continue", "ok", "proceed", "complete", "finish"].contains(l),
           text.range(of: #"[$€£]\s?\d|\d+[.,]\d{2}\s?(usd|eur|gbp)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .purchase
        }
        return nil
    }
}

public enum SensitiveActionPolicy: Sendable, Equatable {
    /// Pause and ask the person before the action runs.
    case askFirst
    /// Do it, but record it in the step log.
    case allow
    /// Never do it; the agent is told to stop and explain.
    case block
}

/// Which categories are gated, and how.
public struct SensitiveActionRules: Sendable, Equatable {
    public var policies: [SensitiveActionCategory: SensitiveActionPolicy]

    public init(policies: [SensitiveActionCategory: SensitiveActionPolicy]) {
        self.policies = policies
    }

    /// Ask before buying, sending and deleting; account changes are blocked.
    public static let `default` = SensitiveActionRules(policies: [
        .purchase: .askFirst, .send: .askFirst, .delete: .askFirst, .account: .block
    ])

    /// Nothing is gated. For trusted tasks and tests.
    public static let permissive = SensitiveActionRules(policies: [:])

    public func policy(for category: SensitiveActionCategory) -> SensitiveActionPolicy {
        policies[category] ?? .allow
    }
}

// MARK: - Steps

/// One completed step, kept for the timeline and the model's history.
public struct AgentStep: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let number: Int
    public let action: AgentAction
    /// What the person saw ("Clicking “Sign in” button").
    public let label: String
    public let thought: String?
    /// One line about what happened after.
    public var outcome: String
    public var succeeded: Bool
    public let startedAt: Date
    public var duration: TimeInterval
    /// Page URL after the step.
    public var url: String
    /// The raw model reply this step was parsed from (nil for steps the
    /// agent took on its own, such as the first navigation).
    public var modelReply: String?

    public init(id: UUID = UUID(), number: Int, action: AgentAction, label: String, thought: String?,
                outcome: String = "", succeeded: Bool = true, startedAt: Date = Date(),
                duration: TimeInterval = 0, url: String = "") {
        self.id = id; self.number = number; self.action = action; self.label = label; self.thought = thought
        self.outcome = outcome; self.succeeded = succeeded; self.startedAt = startedAt; self.duration = duration; self.url = url
    }

    /// Compact line for the model's history block.
    public var historyLine: String {
        "\(number). \(action.compactDescription) → \(succeeded ? "" : "FAILED: ")\(outcome.isEmpty ? "ok" : outcome)"
    }
}

// MARK: - Hand-back summary

/// What changed on the page while the person had control. Fed to the model
/// as plain text when the agent resumes.
public struct HandBackSummary: Sendable, Equatable {
    public let seconds: TimeInterval
    public let urlBefore: String
    public let urlAfter: String
    public let titleAfter: String
    public let note: String?
    public let changedFields: [String]
    public let blockersBefore: [PageBlocker]
    public let blockersAfter: [PageBlocker]

    public var modelText: String {
        var lines = ["The user took over the browser for \(Int(seconds.rounded())) seconds and has handed control back."]
        if urlBefore != urlAfter {
            lines.append("The page changed from \(urlBefore) to \(urlAfter).")
        } else {
            lines.append("The page is still \(urlAfter).")
        }
        if !titleAfter.isEmpty { lines.append("Title now: \(titleAfter).") }
        if !changedFields.isEmpty { lines.append("Fields the user filled: \(changedFields.joined(separator: ", ")).") }
        let cleared = blockersBefore.filter { !blockersAfter.contains($0) }
        if !cleared.isEmpty { lines.append("Resolved: \(cleared.map(\.rawValue).joined(separator: ", ")).") }
        if let note, !note.isEmpty { lines.append("The user says: \(note)") }
        lines.append("Continue the task from the current page. Do not redo what the user did. The page may be scrolled: SCROLL under CURRENT PAGE says how much is above and below you.")
        return lines.joined(separator: " ")
    }
}
