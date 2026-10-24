//
//  AgentOverlays.swift
//  Gepetto
//
//  The layers that sit on top of the live page while an agent runs: a
//  pointer that moves to each target, a touch blocker so a stray tap can't
//  race the agent, and the cards for hand-over and approval. All native
//  SwiftUI; nothing here touches the DOM.
//

import SwiftUI

// MARK: - Cursor

/// A pointer that moves to the element the agent is about to act on and
/// ripples once when it arrives. Motion is driven by actions, never idle.
struct AgentCursorView: View {
    let target: CGRect?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: CGPoint = .zero
    @State private var visible = false
    @State private var ripple = false
    @State private var rippleID = 0

    var body: some View {
        ZStack {
            if visible {
                if !reduceMotion {
                    Circle()
                        .stroke(Color.primary.opacity(0.45), lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                        .scaleEffect(ripple ? 2.4 : 0.6)
                        .opacity(ripple ? 0 : 0.9)
                        .id(rippleID)
                }
                Circle()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            }
        }
        .position(position)
        .allowsHitTesting(false)
        .onChange(of: target) { newValue in
            guard let rect = newValue else {
                withAnimation(.easeOut(duration: 0.2)) { visible = false }
                return
            }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            if !visible {
                position = reduceMotion ? center : CGPoint(x: center.x + 36, y: center.y + 48)
                withAnimation(.easeOut(duration: 0.15)) { visible = true }
            }
            withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .smooth(duration: 0.45)) { position = center }
            guard !reduceMotion else { return }
            rippleID += 1
            ripple = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.easeOut(duration: 0.5)) { ripple = true }
            }
        }
    }
}

// MARK: - Interaction blocker

/// Swallows touches and clicks while the agent drives. Invisible; removed
/// the moment control passes to the person.
struct InteractionBlocker: View {
    let active: Bool
    var body: some View {
        if active {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {}
                #if os(macOS)
                .onHover { _ in }
                #endif
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Cards

/// One glass surface, leading-aligned content, nothing nested.
struct AgentCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(AgentUI.padding)
            .frame(maxWidth: 440, alignment: .leading)
            .agentGlass(in: RoundedRectangle(cornerRadius: AgentUI.radius, style: .continuous))
    }
}

/// Shown while the person has the page. Says what to do, then hands back.
struct TakeoverCard: View {
    let reason: TakeoverReason
    let host: String?
    let onHandBack: (String?) -> Void
    let onStop: () -> Void

    @State private var note = ""

    var body: some View {
        AgentCard {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(reason.title).font(AgentUI.title)
                } icon: {
                    DrawOnSymbol(name: symbol, font: AgentUI.title).id(symbol)
                }
                Text(instruction)
                    .font(AgentUI.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showsAddressWarning {
                    Text("Check the address before you enter a password or a code.")
                        .font(AgentUI.caption)
                        .foregroundStyle(.tertiary)
                }
                TextField("Tell the agent what you did (optional)", text: $note)
                    .textFieldStyle(.plain)
                    .font(AgentUI.body)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: AgentUI.radiusSmall, style: .continuous).fill(AgentUI.inset))
                    .onSubmit { onHandBack(note.isEmpty ? nil : note) }
                HStack(spacing: AgentUI.spacing) {
                    AgentCardButton(title: "Stop", destructive: true, action: onStop)
                        .frame(maxWidth: 96)
                    AgentCardButton(title: "Hand back", symbol: "arrow.uturn.backward", prominent: true) {
                        onHandBack(note.isEmpty ? nil : note)
                    }
                }
                .agentGlassContainer()
            }
        }
    }

    private var symbol: String {
        switch reason {
        case .userInitiated:          return "hand.raised"
        case .blocker(.captcha):      return "checkmark.shield"
        case .blocker(.login):        return "person.badge.key"
        case .blocker(.twoFactor):    return "number"
        case .blocker(.payment):      return "creditcard"
        case .agentAsked:             return "questionmark.bubble"
        }
    }

    /// One sentence saying what to do now: "Sign in to github.com in this tab, then hand back."
    private var instruction: String {
        let site = host ?? "this page"
        switch reason {
        case .userInitiated:          return "Browse, sign in, or fix anything on \(site). Hand back when you're ready."
        case .blocker(.captcha):      return "Complete the verification on \(site), then hand back."
        case .blocker(.login):        return "Sign in to \(site) in this tab, then hand back."
        case .blocker(.twoFactor):    return "Enter the verification code on \(site), then hand back."
        case .blocker(.payment):      return "Enter your payment details on \(site) yourself, then hand back."
        case .agentAsked(let q):      return q
        }
    }

    private var showsAddressWarning: Bool {
        if case .blocker(let b) = reason { return b == .login || b == .twoFactor || b == .payment }
        return false
    }
}

/// "Allow this action?" for purchases, sends, deletes.
struct ApprovalCard: View {
    let summary: String
    let category: SensitiveActionCategory
    let onDecision: (Bool) -> Void

    var body: some View {
        AgentCard {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("Allow this action?").font(AgentUI.title)
                } icon: {
                    DrawOnSymbol(name: symbol, font: AgentUI.title)
                }
                Text(summary)
                    .font(AgentUI.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Asked because it looks like \(reason).")
                    .font(AgentUI.caption)
                    .foregroundStyle(.tertiary)
                HStack(spacing: AgentUI.spacing) {
                    AgentCardButton(title: "Deny") { onDecision(false) }
                    AgentCardButton(title: "Allow", prominent: true) { onDecision(true) }
                }
                .agentGlassContainer()
            }
        }
    }

    private var symbol: String {
        switch category {
        case .purchase: return "cart"
        case .send:     return "paperplane"
        case .delete:   return "trash"
        case .account:  return "person.crop.circle.badge.exclamationmark"
        }
    }

    private var reason: String {
        switch category {
        case .purchase: return "a purchase"
        case .send:     return "it will send or post something"
        case .delete:   return "it deletes something"
        case .account:  return "an account change"
        }
    }
}

// MARK: - Finished / failed toast

struct OutcomeToast: View {
    let success: Bool
    let text: String

    var body: some View {
        Label {
            Text(text).font(AgentUI.bodyMedium).lineLimit(2)
        } icon: {
            DrawOnSymbol(name: success ? "checkmark.circle" : "xmark.circle",
                         font: AgentUI.bodySemibold, color: success ? .green : .red)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .agentGlass(in: Capsule())
    }
}
