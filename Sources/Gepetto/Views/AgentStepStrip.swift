//
//  AgentStepStrip.swift
//  Gepetto
//
//  The line that says what the agent is doing, and the row of steps it has
//  taken. Tapping a step shows what happened after it.
//

import SwiftUI

/// What the agent is doing right now, with the model's reasoning under it.
/// The only moving part is a system spinner while it works.
struct AgentThoughtLine: View {
    let phase: AgentPhase
    let thought: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AgentUI.spacing) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                DrawOnSymbol(name: phase.symbol, font: AgentUI.bodySemibold, color: statusColor)
                    .frame(width: 16, height: 16)
                    .id(phase.symbol)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(phase.label)
                    .font(AgentUI.bodySemibold)
                    .foregroundStyle(.primary)
                if let thought, !thought.isEmpty {
                    Text(thought)
                        .font(AgentUI.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let detail = phase.detail {
                    Text(detail)
                        .font(AgentUI.caption)
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

    private var isBusy: Bool {
        switch phase {
        case .idle, .finished, .failed, .paused, .handedOver, .awaitingApproval, .awaitingAnswer: return false
        default: return true
        }
    }

    /// Colour only for true status.
    private var statusColor: Color {
        switch phase {
        case .failed:   return .red
        case .finished: return .green
        default:        return .secondary
        }
    }
}

/// Horizontal timeline. The current step is primary; earlier ones recede.
struct AgentStepStrip: View {
    let steps: [AgentStep]
    @State private var expanded: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(steps) { step in
                            StepChip(step: step, isCurrent: step.id == steps.last?.id, isExpanded: expanded == step.id)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        expanded = expanded == step.id ? nil : step.id
                                    }
                                }
                                .id(step.id)
                        }
                    }
                    .padding(.horizontal, AgentUI.padding)
                }
                .onChange(of: steps.count) { _ in
                    if let last = steps.last {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .trailing) }
                    }
                }
            }
            if let id = expanded, let step = steps.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 2) {
                    if let thought = step.thought, !thought.isEmpty {
                        Text(thought)
                            .font(AgentUI.caption)
                            .foregroundStyle(.primary)
                    }
                    Text(step.outcome.isEmpty ? "No result recorded." : step.outcome)
                        .font(AgentUI.captionSecondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                .padding(.horizontal, AgentUI.padding)
                .transition(.opacity)
            }
        }
    }
}

private struct StepChip: View {
    let step: AgentStep
    let isCurrent: Bool
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("\(step.number)")
                .font(AgentUI.captionSecondary.monospacedDigit())
                .foregroundStyle(.tertiary)
            DrawOnSymbol(name: step.succeeded ? step.action.symbol : "exclamationmark.triangle",
                         font: AgentUI.captionSecondary.weight(.semibold),
                         color: step.succeeded ? (isCurrent ? Color.primary : Color.secondary) : Color.red)
            Text(step.label)
                .font(isCurrent ? AgentUI.caption.weight(.medium) : AgentUI.caption)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 240, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: AgentUI.radiusSmall, style: .continuous)
                .fill(isExpanded || isCurrent ? AgentUI.insetSelected : AgentUI.inset)
        )
        .transition(.opacity)
    }
}
