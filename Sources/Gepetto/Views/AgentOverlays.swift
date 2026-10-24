//
//  AgentOverlays.swift
//  Gepetto
//
//  The layers that sit on top of the live web view while an agent runs:
//  an animated cursor that moves to each target, a touch blocker so a
//  stray tap can't race the agent, and the cards for hand-over, approval
//  and questions. All native SwiftUI; nothing here touches the DOM.
//

import SwiftUI

// MARK: - Cursor

/// A translucent pointer that glides to the element the agent is about to
/// act on and ripples when it gets there.
struct AgentCursorView: View {
    let target: CGRect?
    let accent: Color

    @State private var position: CGPoint = .zero
    @State private var visible = false
    @State private var ripple = false
    @State private var rippleID = 0

    var body: some View {
        ZStack {
            if visible {
                Circle()
                    .stroke(accent.opacity(0.55), lineWidth: 2)
                    .frame(width: 22, height: 22)
                    .scaleEffect(ripple ? 2.6 : 0.6)
                    .opacity(ripple ? 0 : 0.9)
                    .id(rippleID)
                Circle()
                    .fill(accent.opacity(0.82))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .shadow(color: accent.opacity(0.45), radius: 8, y: 2)
            }
        }
        .position(position)
        .allowsHitTesting(false)
        .onChange(of: target) { newValue in
            guard let rect = newValue else {
                withAnimation(.easeOut(duration: 0.25)) { visible = false }
                return
            }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            if !visible {
                position = CGPoint(x: center.x + 40, y: center.y + 60)
                withAnimation(.easeOut(duration: 0.2)) { visible = true }
            }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { position = center }
            rippleID += 1
            ripple = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.easeOut(duration: 0.6)) { ripple = true }
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

// MARK: - Shared card chrome

struct AgentCard<Content: View>: View {
    let accent: Color
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 22, y: 10)
    }
}

struct AgentCardButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    let kind: Kind
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .foregroundStyle(foreground)
            .background(Capsule().fill(background))
            .overlay(Capsule().stroke(Color.primary.opacity(kind == .secondary ? 0.12 : 0), lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary:     return .white
        case .secondary:   return .primary
        case .destructive: return .red
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .primary:     return AnyShapeStyle(accent)
        case .secondary:   return AnyShapeStyle(Color.primary.opacity(0.06))
        case .destructive: return AnyShapeStyle(Color.red.opacity(0.1))
        }
    }
}

// MARK: - Hand-over card

/// Shown while the person has the page. Says what to do, then hands back.
struct TakeoverCard: View {
    let reason: TakeoverReason
    let host: String?
    let accent: Color
    let onHandBack: (String?) -> Void
    let onStop: () -> Void

    @State private var note = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        AgentCard(accent: accent) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(accent.opacity(0.15)).frame(width: 34, height: 34)
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reason.title)
                            .font(.headline)
                        Text(instruction)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if showsAddressWarning {
                    Label("Check the address before you enter a password or a code.", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Tell the agent what you did (optional)", text: $note)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                    .focused($noteFocused)
                    .onSubmit { onHandBack(note.isEmpty ? nil : note) }
                HStack(spacing: 10) {
                    Button("Stop", action: onStop)
                        .buttonStyle(AgentCardButtonStyle(kind: .destructive, accent: accent))
                        .frame(maxWidth: 110)
                    Button {
                        onHandBack(note.isEmpty ? nil : note)
                    } label: {
                        Label("Hand back to agent", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(AgentCardButtonStyle(kind: .primary, accent: accent))
                }
            }
        }
    }

    private var symbol: String {
        switch reason {
        case .userInitiated:                   return "hand.raised.fill"
        case .blocker(.captcha):               return "checkmark.shield"
        case .blocker(.login):                 return "person.badge.key"
        case .blocker(.twoFactor):             return "number.square"
        case .blocker(.payment):               return "creditcard"
        case .agentAsked:                      return "questionmark.bubble"
        }
    }

    /// One sentence saying what to do now, in the style of "Sign in to
    /// github.com in this tab, then hand back."
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

// MARK: - Approval card

/// "Allow this action?" for purchases, sends, deletes.
struct ApprovalCard: View {
    let summary: String
    let category: SensitiveActionCategory
    let accent: Color
    let onDecision: (Bool) -> Void

    var body: some View {
        AgentCard(accent: accent) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Color.orange.opacity(0.15)).frame(width: 34, height: 34)
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow this action?")
                            .font(.headline)
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Asked because it looks like \(reason).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Deny") { onDecision(false) }
                        .buttonStyle(AgentCardButtonStyle(kind: .secondary, accent: accent))
                    Button("Allow") { onDecision(true) }
                        .buttonStyle(AgentCardButtonStyle(kind: .primary, accent: accent))
                }
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
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(success ? Color.green : Color.red)
            Text(text)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
    }
}
