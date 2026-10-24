//
//  AgentBrowserPanel.swift
//  Gepetto
//
//  The complete live view of an agent run, ready to drop into a chat or a
//  sheet: a glass panel holding the page, the controls, the thought line
//  and the timeline. Cards for hand-over and approval appear over the page.
//
//  Binds to `BrowserAgent`; the controls call its pause / takeOver /
//  handBack / respond / stop API.
//

import SwiftUI
import WebKit

public struct AgentBrowserPanel: View {
    @ObservedObject public var agent: BrowserAgent

    /// Height of the page area. Nil fills the available space.
    public var stageHeight: CGFloat?
    /// Show the title row with the controls.
    public var showsHeader: Bool
    /// Show the thought line and step timeline under the page.
    public var showsTimeline: Bool
    /// Called when the person closes the panel.
    public var onClose: (() -> Void)?

    @State private var toast: (success: Bool, text: String)?

    public init(agent: BrowserAgent,
                stageHeight: CGFloat? = nil,
                showsHeader: Bool = true,
                showsTimeline: Bool = true,
                onClose: (() -> Void)? = nil) {
        self.agent = agent
        self.stageHeight = stageHeight
        self.showsHeader = showsHeader
        self.showsTimeline = showsTimeline
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader { header }
            stage
            if showsTimeline { footer }
        }
        .agentGlass(in: RoundedRectangle(cornerRadius: AgentUI.radiusLarge, style: .continuous))
        .agentPanelShadow()
        .onChange(of: agent.controlState) { state in
            guard case .finished(let ok) = state else { return }
            withAnimation(.easeInOut(duration: 0.2)) { toast = (ok, ok ? "Finished" : agent.currentPhase.label) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(.easeOut(duration: 0.2)) { toast = nil }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: AgentUI.spacing) {
            if let engine = agent.executor?.engine {
                FaviconView(engine: engine)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.currentTitle?.isEmpty == false ? agent.currentTitle! : (host ?? "Browser"))
                    .font(AgentUI.title)
                    .lineLimit(1)
                if let host, agent.currentTitle?.isEmpty == false {
                    Text(host)
                        .font(AgentUI.captionSecondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(0)
            Spacer(minLength: 8)
            // The controls never wrap or truncate; the title gives way.
            HStack(spacing: AgentUI.spacing) { controls }
                .fixedSize()
                .layoutPriority(1)
                .agentGlassContainer()
        }
        .padding(.horizontal, AgentUI.padding)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var controls: some View {
        switch agent.controlState {
        case .running:
            GlassIconButton(symbol: "pause", label: "Pause") { agent.pause() }
            GlassPillButton(title: "Take over", symbol: "hand.raised", prominent: true) { agent.takeOver() }
            GlassIconButton(symbol: "xmark", label: "Stop") { agent.stop() }
        case .paused:
            GlassPillButton(title: "Resume", symbol: "play", prominent: true) { agent.resume() }
            GlassIconButton(symbol: "hand.raised", label: "Take over") { agent.takeOver() }
            GlassIconButton(symbol: "xmark", label: "Stop") { agent.stop() }
        case .waitingForUser(.takeover):
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                Text("You're in control").font(AgentUI.bodySemibold)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .agentGlass(in: Capsule())
            GlassPillButton(title: "Hand back", symbol: "arrow.uturn.backward", prominent: true) { agent.handBack() }
        case .waitingForUser:
            GlassIconButton(symbol: "hand.raised", label: "Take over") { agent.takeOver() }
            GlassIconButton(symbol: "xmark", label: "Stop") { agent.stop() }
        case .stopping:
            ProgressView().controlSize(.small)
        case .idle, .finished:
            if let onClose {
                GlassIconButton(symbol: "xmark", label: "Close") { onClose() }
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
                    AgentCursorView(target: agent.activeTargetFrame)
                    LoadingBar(engine: engine)
                }
            } else {
                startingState
            }

            cards
                .padding(12)

            if let toast {
                OutcomeToast(success: toast.success, text: toast.text)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .frame(height: stageHeight)
        .frame(maxWidth: .infinity, maxHeight: stageHeight == nil ? .infinity : nil)
        .clipShape(RoundedRectangle(cornerRadius: AgentUI.radiusStage, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AgentUI.radiusStage, style: .continuous).strokeBorder(AgentUI.hairline, lineWidth: 0.5))
        .padding(.horizontal, 10)
        .padding(.bottom, showsTimeline ? 10 : 10)
        .padding(.top, showsHeader ? 0 : 10)
        .animation(.easeInOut(duration: 0.25), value: agent.controlState)
    }

    @ViewBuilder private var cards: some View {
        switch agent.controlState {
        case .waitingForUser(.takeover(let reason)):
            TakeoverCard(reason: reason, host: host,
                         onHandBack: { note in agent.handBack(note: note) },
                         onStop: { agent.stop() })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .waitingForUser(.confirm(_, let summary, let category)):
            ApprovalCard(summary: summary, category: category) { allow in agent.respond(allow: allow) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .waitingForUser(.question(let q)):
            TakeoverCard(reason: .agentAsked(question: q), host: host,
                         onHandBack: { note in agent.answer(note ?? "") },
                         onStop: { agent.stop() })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        default:
            EmptyView()
        }
    }

    private var startingState: some View {
        HStack(spacing: AgentUI.spacing) {
            ProgressView().controlSize(.small)
            Text("Starting browser")
                .font(AgentUI.body)
                .foregroundStyle(.secondary)
        }
        .padding(AgentUI.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentThoughtLine(phase: agent.currentPhase, thought: agent.currentThought)
                .padding(.horizontal, AgentUI.padding)
            if !agent.steps.isEmpty {
                AgentStepStrip(steps: agent.steps)
            }
        }
        .padding(.bottom, 14)
        .animation(.easeInOut(duration: 0.2), value: agent.steps.count)
    }
}

/// Thin progress line along the top of the page while it loads.
struct LoadingBar: View {
    @ObservedObject var engine: BrowserEngine

    var body: some View {
        GeometryReader { geo in
            if engine.isLoading {
                Rectangle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: max(12, geo.size.width * engine.loadingProgress), height: 2)
                    .animation(.easeOut(duration: 0.25), value: engine.loadingProgress)
                    .transition(.opacity)
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}
