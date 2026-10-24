//
//  AgentStepStrip.swift
//  Gepetto
//
//  The horizontal timeline of what the agent has done, plus the live
//  "thinking" line above it. Tapping a step shows what happened after it.
//

import SwiftUI

struct AgentStepStrip: View {
    let steps: [AgentStep]
    let accent: Color
    @State private var expanded: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(steps) { step in
                            StepChip(step: step, isLast: step.id == steps.last?.id, accent: accent,
                                     isExpanded: expanded == step.id)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        expanded = expanded == step.id ? nil : step.id
                                    }
                                }
                                .id(step.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
                }
                .onChange(of: steps.count) { _ in
                    if let last = steps.last { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(last.id, anchor: .trailing) } }
                }
            }
            if let id = expanded, let step = steps.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 3) {
                    if let thought = step.thought, !thought.isEmpty {
                        Text(thought)
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    Text(step.outcome.isEmpty ? "No result recorded." : step.outcome)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                .padding(.horizontal, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct StepChip: View {
    let step: AgentStep
    let isLast: Bool
    let accent: Color
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(step.succeeded ? (isLast ? accent : accent.opacity(0.18)) : Color.red.opacity(0.18))
                    .frame(width: 20, height: 20)
                Image(systemName: step.succeeded ? step.action.symbol : "exclamationmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(step.succeeded ? (isLast ? Color.white : accent) : Color.red)
            }
            Text(step.label)
                .font(.caption.weight(isLast ? .semibold : .regular))
                .foregroundStyle(isLast ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 170, alignment: .leading)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(isExpanded ? accent.opacity(0.12) : Color.primary.opacity(0.05)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// The agent's reasoning for the current step, shimmering while it thinks.
struct AgentThoughtLine: View {
    let phase: AgentPhase
    let thought: String?
    let accent: Color
    @State private var shimmer = false

    private var isThinking: Bool { if case .thinking = phase { return true }; return false }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PhaseIndicator(phase: phase, accent: accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(phase.label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.opacity)
                if let thought, !thought.isEmpty {
                    Text(thought)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .overlay(shimmerOverlay)
                        .transition(.opacity)
                } else if let detail = phase.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.2), value: phase)
        .animation(.easeInOut(duration: 0.2), value: thought)
    }

    @ViewBuilder private var shimmerOverlay: some View {
        if isThinking {
            LinearGradient(colors: [.clear, Color.primary.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 120)
                .offset(x: shimmer ? 260 : -160)
                .mask(Text(thought ?? "").font(.caption).lineLimit(2))
                .onAppear { withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { shimmer = true } }
                .onDisappear { shimmer = false }
        }
    }
}

/// A small status dot: pulsing while the agent works, solid when it waits.
struct PhaseIndicator: View {
    let phase: AgentPhase
    let accent: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.18)).frame(width: 22, height: 22)
            if isBusy {
                Circle().stroke(color.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                    .scaleEffect(pulse ? 1.6 : 1)
                    .opacity(pulse ? 0 : 0.8)
                    .onAppear { withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true } }
                    .onDisappear { pulse = false }
            }
            Image(systemName: phase.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: 24, height: 24)
    }

    private var isBusy: Bool {
        switch phase {
        case .idle, .finished, .failed, .paused, .handedOver, .awaitingApproval, .awaitingAnswer: return false
        default: return true
        }
    }

    private var color: Color {
        switch phase {
        case .failed:                                   return .red
        case .finished:                                 return .green
        case .handedOver, .awaitingApproval, .awaitingAnswer, .paused: return .orange
        default:                                        return accent
        }
    }
}
