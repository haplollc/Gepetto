//
//  AgentBrowserPanel.swift
//  Gepetto
//
//  The complete live view of an agent run, ready to drop into a chat or a
//  sheet:
//
//    ┌ host · title                     ⏸  ✋ Take over  ✕ ┐
//    │ ▁▁▁ loading                                        │
//    │ ┌───────────────── web view ─────────────────────┐ │
//    │ │  numbered marks on the page, a cursor that      │ │
//    │ │  glides to each target, cards for hand-over     │ │
//    │ │  and approval                                   │ │
//    │ └────────────────────────────────────────────────┘ │
//    │ ◉ Thinking…  "The results list is below, scroll"   │
//    │ ① Opened hn.com ▸ ② Typed “…” ▸ ③ Clicked …        │
//    └────────────────────────────────────────────────────┘
//
//  Binds to `BrowserAgent`; the controls call its pause / takeOver /
//  handBack / respond / stop API.
//

import SwiftUI
import WebKit

public struct AgentBrowserPanel: View {
    @ObservedObject public var agent: BrowserAgent

    /// Height of the web view area. Nil fills the available space.
    public var stageHeight: CGFloat?
    /// Accent for marks, cursor and primary buttons.
    public var accent: Color
    /// Show the host/title header with the controls.
    public var showsHeader: Bool
    /// Show the thought line and step timeline under the page.
    public var showsTimeline: Bool
    /// Called when the person closes the panel.
    public var onClose: (() -> Void)?

    @State private var showMarks: Bool
    @State private var toast: (success: Bool, text: String)?

    public init(agent: BrowserAgent,
                stageHeight: CGFloat? = nil,
                accent: Color = .accentColor,
                showsHeader: Bool = true,
                showsTimeline: Bool = true,
                onClose: (() -> Void)? = nil) {
        self.agent = agent
        self.stageHeight = stageHeight
        self.accent = accent
        self.showsHeader = showsHeader
        self.showsTimeline = showsTimeline
        self.onClose = onClose
        _showMarks = State(initialValue: agent.configuration.showMarks)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showsHeader { header }
            stage
            if showsTimeline { footer }
        }
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .onChange(of: agent.controlState) { state in
            switch state {
            case .finished(let ok):
                let text = ok ? "Finished" : (agent.currentPhase.label)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { toast = (ok, text) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation(.easeOut(duration: 0.3)) { toast = nil }
                }
            default:
                break
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            SiteGlyph(url: agent.currentURL, accent: accent, isLoading: agent.executor?.engine?.isLoading ?? false)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.currentTitle?.isEmpty == false ? agent.currentTitle! : (host ?? "Browser"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let host, agent.currentTitle?.isEmpty == false {
                    Text(host)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            controls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var controls: some View {
        switch agent.controlState {
        case .running:
            CircleButton(symbol: "pause.fill", help: "Pause") { agent.pause() }
            PillButton(title: "Take over", symbol: "hand.raised.fill", accent: accent) { agent.takeOver() }
            CircleButton(symbol: "xmark", help: "Stop") { agent.stop() }
        case .paused:
            PillButton(title: "Resume", symbol: "play.fill", accent: accent) { agent.resume() }
            CircleButton(symbol: "hand.raised.fill", help: "Take over") { agent.takeOver() }
            CircleButton(symbol: "xmark", help: "Stop") { agent.stop() }
        case .waitingForUser(.takeover):
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Text("You're in control").font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color.red.opacity(0.1)))
            PillButton(title: "Hand back", symbol: "arrow.uturn.backward", accent: accent) { agent.handBack() }
        case .waitingForUser:
            CircleButton(symbol: "hand.raised.fill", help: "Take over") { agent.takeOver() }
            CircleButton(symbol: "xmark", help: "Stop") { agent.stop() }
        case .stopping:
            ProgressView().controlSize(.small)
        case .idle, .finished:
            Menu {
                Toggle("Show what the agent sees", isOn: $showMarks)
                if let url = agent.currentURL.flatMap(URL.init(string:)) {
                    ShareLink(item: url) { Label("Share page", systemImage: "square.and.arrow.up") }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30, height: 30)
            if let onClose {
                CircleButton(symbol: "xmark", help: "Close") { onClose() }
            }
        }
    }

    private var host: String? {
        guard let url = agent.currentURL, let u = URL(string: url), let h = u.host else { return nil }
        return h.replacingOccurrences(of: "www.", with: "")
    }

    // MARK: Stage

    private var stage: some View {
        ZStack(alignment: .bottom) {
            if let engine = agent.executor?.engine {
                ZStack(alignment: .topLeading) {
                    WebViewRepresentable(webView: engine.webView)
                    InteractionBlocker(active: !engine.acceptsUserInput)
                    AgentCursorView(target: agent.activeTargetFrame, accent: accent)
                    LoadingBar(engine: engine, accent: accent)
                }
            } else {
                startingState
            }

            // Edge glow while the agent drives: the page is "live".
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(stageBorder, lineWidth: agent.controlState == .running ? 1.5 : 0.5)
                .allowsHitTesting(false)

            cards
                .padding(12)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: agent.controlState)

            if let toast {
                OutcomeToast(success: toast.success, text: toast.text, accent: accent)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(height: stageHeight)
        .frame(maxWidth: .infinity, maxHeight: stageHeight == nil ? .infinity : nil)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, showsTimeline ? 8 : 10)
        .padding(.top, showsHeader ? 0 : 10)
    }

    private var stageBorder: AnyShapeStyle {
        switch agent.controlState {
        case .running:
            return AnyShapeStyle(LinearGradient(colors: [accent.opacity(0.7), accent.opacity(0.15), accent.opacity(0.7)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        case .waitingForUser(.takeover):
            return AnyShapeStyle(Color.red.opacity(0.5))
        default:
            return AnyShapeStyle(Color.primary.opacity(0.1))
        }
    }

    @ViewBuilder private var cards: some View {
        switch agent.controlState {
        case .waitingForUser(.takeover(let reason)):
            TakeoverCard(reason: reason, host: host, accent: accent,
                         onHandBack: { note in agent.handBack(note: note) },
                         onStop: { agent.stop() })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .waitingForUser(.confirm(_, let summary, let category)):
            ApprovalCard(summary: summary, category: category, accent: accent) { allow in agent.respond(allow: allow) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .waitingForUser(.question(let q)):
            TakeoverCard(reason: .agentAsked(question: q), host: host, accent: accent,
                         onHandBack: { note in agent.answer(note ?? "") },
                         onStop: { agent.stop() })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        default:
            EmptyView()
        }
    }

    private var startingState: some View {
        VStack(spacing: 10) {
            Image(systemName: "safari")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Starting browser…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressView().controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentThoughtLine(phase: agent.currentPhase, thought: agent.currentThought, accent: accent)
                .padding(.horizontal, 14)
            if !agent.steps.isEmpty {
                AgentStepStrip(steps: agent.steps, accent: accent)
            }
        }
        .padding(.bottom, 12)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: agent.steps.count)
    }
}

// MARK: - Small controls

struct CircleButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct PillButton: View {
    let title: String
    let symbol: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .foregroundStyle(.white)
                .background(Capsule().fill(accent))
        }
        .buttonStyle(.plain)
    }
}

/// A favicon stand-in: the first letter of the host in an accent circle,
/// with a spinner while the page loads.
struct SiteGlyph: View {
    let url: String?
    let accent: Color
    let isLoading: Bool

    var body: some View {
        ZStack {
            Circle().fill(accent.opacity(0.14)).frame(width: 30, height: 30)
            if isLoading {
                ProgressView().controlSize(.mini)
            } else if let letter {
                Text(letter)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
    }

    private var letter: String? {
        guard let url, let host = URL(string: url)?.host?.replacingOccurrences(of: "www.", with: ""),
              let c = host.first else { return nil }
        return String(c).uppercased()
    }
}

/// Thin progress bar along the top of the stage while a page loads.
struct LoadingBar: View {
    @ObservedObject var engine: BrowserEngine
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            if engine.isLoading {
                Capsule()
                    .fill(accent)
                    .frame(width: max(12, geo.size.width * engine.loadingProgress), height: 2.5)
                    .animation(.easeOut(duration: 0.25), value: engine.loadingProgress)
                    .transition(.opacity)
            }
        }
        .frame(height: 2.5)
        .allowsHitTesting(false)
    }
}
