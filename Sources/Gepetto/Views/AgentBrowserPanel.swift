//
//  AgentBrowserPanel.swift
//  Gepetto
//
//  The complete live view of an agent run, ready to drop into a chat or a
//  sheet: a glass panel holding the page, the controls, the thought line
//  and the timeline. The approval and answer cards appear over the page;
//  during a takeover a compact bar sits along the bottom of the page so
//  the page itself stays usable, and the page's own alert / confirm /
//  prompt dialogs come up as native alerts.
//
//  Binds to `BrowserAgent`; the controls call its pause / takeOver /
//  handBack / respond / answer / stop API. The title row reads the live
//  engine, so it keeps up while the person browses.
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
    /// Called when the person collapses the panel. The control sits next to
    /// Close while the agent is idle or finished; nil hides it.
    public var onCollapse: (() -> Void)?

    @State private var toast: (success: Bool, text: String)?

    public init(agent: BrowserAgent,
                stageHeight: CGFloat? = nil,
                showsHeader: Bool = true,
                showsTimeline: Bool = true,
                onClose: (() -> Void)? = nil,
                onCollapse: (() -> Void)? = nil) {
        self.agent = agent
        self.stageHeight = stageHeight
        self.showsHeader = showsHeader
        self.showsTimeline = showsTimeline
        self.onClose = onClose
        self.onCollapse = onCollapse
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
                LivePageHeading(engine: engine, fallbackTitle: agent.currentTitle, fallbackHost: host)
                    .layoutPriority(0)
            } else {
                PageHeading(title: agent.currentTitle, host: host)
                    .layoutPriority(0)
            }
            Spacer(minLength: 8)
            // The controls never wrap or truncate; the title gives way. Each
            // control carries a 4 pt hit margin around its 36 pt glass, so
            // zero stack spacing keeps the visual gaps at 8 pt.
            HStack(spacing: 0) { controls }
                .fixedSize()
                .layoutPriority(1)
                .agentGlassContainer()
        }
        .padding(.leading, AgentUI.padding)
        .padding(.trailing, AgentUI.padding - AgentUI.hitMargin)
        // 8 + 44 + 6: the 58 pt the row had with 36 pt controls.
        .padding(.top, 8)
        .padding(.bottom, 6)
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
            .frame(height: AgentUI.controlSize)
            .agentGlass(in: Capsule())
            .padding(AgentUI.hitMargin)
            // Hand back lives on the bar at the bottom of the page, next to
            // what the person is doing; the header only says who is driving.
        case .waitingForUser:
            GlassIconButton(symbol: "hand.raised", label: "Take over") { agent.takeOver() }
            GlassIconButton(symbol: "xmark", label: "Stop") { agent.stop() }
        case .stopping:
            ProgressView()
                .controlSize(.small)
                .frame(width: AgentUI.hitTarget, height: AgentUI.hitTarget)
        case .idle, .finished:
            if let onCollapse {
                GlassIconButton(symbol: "chevron.down", label: "Collapse") { onCollapse() }
            }
            if let onClose {
                GlassIconButton(symbol: "xmark", label: "Close") { onClose() }
            }
        }
    }

    /// Host of the page the agent last read: the header's fallback while
    /// there is no engine yet.
    private var host: String? {
        guard let url = agent.currentURL, let u = URL(string: url), let h = u.host else { return nil }
        return displayHost(h)
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
                .modifier(PageDialogPresenter(engine: engine))
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
            TakeoverBar(reason: reason,
                        onHandBack: { note in agent.handBack(note: note) },
                        onStop: { agent.stop() })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .waitingForUser(.confirm(_, let summary, let category)):
            ApprovalCard(summary: summary, category: category) { allow in agent.respond(allow: allow) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .waitingForUser(.question(let question)):
            AnswerCard(question: question,
                       onAnswer: { text in agent.answer(text) },
                       onTakeOver: { agent.takeOver() })
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
        VStack(alignment: .leading, spacing: 2) {
            AgentThoughtLine(phase: agent.currentPhase, thought: agent.currentThought)
                .padding(.horizontal, AgentUI.padding)
            if !agent.steps.isEmpty {
                // The chips carry an 8 pt hit margin above and below, which
                // supplies the visual gaps: 2 + 8 above, 6 + 8 below.
                AgentStepStrip(steps: agent.steps)
            }
        }
        .padding(.bottom, agent.steps.isEmpty ? 14 : 6)
        .animation(.easeInOut(duration: 0.2), value: agent.steps.count)
    }
}

// MARK: - Header pieces

/// "www." adds nothing in a header.
private func displayHost(_ host: String) -> String {
    host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

/// Title over host. The host caption appears only when the title line is
/// not already the host.
private struct PageHeading: View {
    let title: String?
    let host: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(shownTitle ?? host ?? "Browser")
                .font(AgentUI.title)
                .lineLimit(1)
            if let host, shownTitle != nil {
                Text(host)
                    .font(AgentUI.captionSecondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var shownTitle: String? { title.flatMap { $0.isEmpty ? nil : $0 } }
}

/// The page the web view is actually on, live, so the header keeps up
/// while the person browses during a takeover. The agent's step-boundary
/// copies are the fallback until the engine has a page of its own.
private struct LivePageHeading: View {
    @ObservedObject var engine: BrowserEngine
    let fallbackTitle: String?
    let fallbackHost: String?

    var body: some View {
        if let liveHost = engine.currentURL?.host.map(displayHost) {
            // A new document's title arrives after it commits; until then
            // the host stands in for it.
            PageHeading(title: engine.pageTitle, host: liveHost)
        } else {
            PageHeading(title: fallbackTitle, host: fallbackHost)
        }
    }
}

// MARK: - Page dialogs

/// The page's own alert / confirm / prompt, parked by the engine while the
/// person has the page, shown as a native alert and answered through
/// `BrowserEngine.respond(to:ok:text:)`.
private struct PageDialogPresenter: ViewModifier {
    @ObservedObject var engine: BrowserEngine
    @State private var promptText = ""
    @State private var respondedID: UUID?

    func body(content: Content) -> some View {
        content
            .alert("This page says", isPresented: isPresented, presenting: engine.pendingDialog) { dialog in
                if case .prompt = dialog.kind {
                    TextField("Your answer", text: $promptText)
                }
                if case .alert = dialog.kind {
                    Button("OK") { respond(to: dialog, ok: true) }
                } else {
                    Button("Cancel", role: .cancel) { respond(to: dialog, ok: false) }
                    Button("OK") { respond(to: dialog, ok: true) }
                }
            } message: { dialog in
                Text(dialog.message)
            }
            .onAppear { promptText = engine.pendingDialog?.defaultText ?? "" }
            .onChange(of: engine.pendingDialog?.id) { _ in promptText = engine.pendingDialog?.defaultText ?? "" }
    }

    private func respond(to dialog: BrowserDialog, ok: Bool) {
        respondedID = dialog.id
        var text: String?
        if case .prompt = dialog.kind, ok { text = promptText }
        engine.respond(to: dialog.id, ok: ok, text: text)
    }

    /// Follows `pendingDialog`. A dismissal that did not come through a
    /// button (Escape on the Mac, the panel going away) reaches the page
    /// as a cancel, once any button action has had its turn.
    private var isPresented: Binding<Bool> {
        Binding(
            get: { engine.pendingDialog != nil },
            set: { shown in
                guard !shown, let id = engine.pendingDialog?.id else { return }
                DispatchQueue.main.async {
                    guard respondedID != id, engine.pendingDialog?.id == id else { return }
                    engine.respond(to: id, ok: false)
                }
            })
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
