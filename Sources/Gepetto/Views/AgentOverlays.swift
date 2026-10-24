//
//  AgentOverlays.swift
//  Gepetto
//
//  The layers that sit on top of the live page while an agent runs: a
//  pointer that moves to each target, a touch blocker so a stray tap can't
//  race the agent, the compact bar for a takeover, and the cards for an
//  approval and for a question. All native SwiftUI; nothing here touches
//  the DOM.
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

/// Shown while the person has the page. One 56 pt row docked along the
/// bottom of the stage, so the page above it stays usable: the symbol,
/// what to do, and Hand back. A note for the agent and Stop sit behind a
/// small disclosure; the address warning for sign-in, code and payment
/// pages is a caption under the row.
struct TakeoverBar: View {
    let reason: TakeoverReason
    let onHandBack: (String?) -> Void
    let onStop: () -> Void

    @State private var note = ""
    @State private var showsNote = false
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 0) {
                DrawOnSymbol(name: symbol, font: AgentUI.bodySemibold)
                    .id(symbol)
                    .frame(width: 20, alignment: .leading)
                Text(instruction)
                    .font(AgentUI.body)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
                    .padding(.trailing, 4)
                GlassIconButton(symbol: showsNote ? "chevron.down" : "square.and.pencil",
                                label: showsNote ? "Hide the note" : "Add a note") { toggleNote() }
                GlassPillButton(title: "Hand back", prominent: true) { handBack() }
            }
            .agentGlassContainer()
            if showsAddressWarning {
                Text("Check the address before you enter a password or code.")
                    .font(AgentUI.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, AgentUI.hitMargin)
            }
            if showsNote {
                HStack(spacing: AgentUI.spacing) {
                    TextField("Note for the agent (optional)", text: $note)
                        .agentField()
                        .focused($noteFocused)
                        .submitLabel(.done)
                        .onSubmit { handBack() }
                    AgentCardButton(title: "Stop", destructive: true, action: onStop)
                        .frame(width: 84)
                }
                .padding(.trailing, AgentUI.hitMargin)
                .transition(.opacity)
            }
        }
        // The controls carry a 4 pt hit margin, so the trailing inset is
        // 8 + 4: the glass sits 12 pt from both edges.
        .padding(.leading, 12)
        .padding(.trailing, 12 - AgentUI.hitMargin)
        .padding(.vertical, 6)
        .frame(maxWidth: 440, alignment: .leading)
        .agentGlass(in: RoundedRectangle(cornerRadius: AgentUI.radius, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: showsNote)
    }

    private func toggleNote() {
        showsNote.toggle()
        guard showsNote else {
            noteFocused = false
            return
        }
        // Let the field appear before it takes focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { noteFocused = true }
    }

    private func handBack() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        onHandBack(trimmed.isEmpty ? nil : trimmed)
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

    /// What to do now, short enough for two lines beside the buttons on a
    /// phone. The header shows which site this is.
    private var instruction: String {
        switch reason {
        case .userInitiated:          return "Browse or sign in, then hand back."
        case .blocker(.captcha):      return "Finish the check, then hand back."
        case .blocker(.login):        return "Sign in, then hand back."
        case .blocker(.twoFactor):    return "Enter the code, then hand back."
        case .blocker(.payment):      return "Complete payment, then hand back."
        case .agentAsked(let q):      return q
        }
    }

    private var showsAddressWarning: Bool {
        if case .blocker(let b) = reason { return b == .login || b == .twoFactor || b == .payment }
        return false
    }
}

/// The agent asked something it needs a reply to. The question leads; the
/// answer goes back as text. Taking over the page instead is the second
/// way out.
struct AnswerCard: View {
    let question: String
    let onAnswer: (String) -> Void
    let onTakeOver: () -> Void

    @State private var answer = ""

    var body: some View {
        AgentCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: AgentUI.spacing) {
                    DrawOnSymbol(name: "questionmark.bubble", font: AgentUI.title)
                    Text(question)
                        .font(AgentUI.title)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField("Your answer", text: $answer)
                    .agentField()
                    .submitLabel(.send)
                    .onSubmit { send() }
                HStack(spacing: AgentUI.spacing) {
                    AgentCardButton(title: "Take over", symbol: "hand.raised", action: onTakeOver)
                        .frame(maxWidth: 132)
                    AgentCardButton(title: "Send answer", symbol: "arrow.up", prominent: true) { send() }
                        .disabled(trimmed.isEmpty)
                }
                .agentGlassContainer()
            }
        }
    }

    private var trimmed: String { answer.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        guard !trimmed.isEmpty else { return }
        onAnswer(trimmed)
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
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Asked because it looks like \(reason).")
                    .font(AgentUI.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
