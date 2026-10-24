//
//  AgentUI.swift
//  Gepetto
//
//  The handful of values every Gepetto view draws from, and the glass
//  helper that wraps Liquid Glass on iOS 26 / macOS 26 and falls back to a
//  material below that. Chrome (the panel, buttons, cards, the toast) is
//  glass; content (the page, text, the timeline) is plain.
//

import SwiftUI

enum AgentUI {
    /// Large floating surface: the panel.
    static let radiusLarge: CGFloat = 24
    /// Cards, the page region, buttons.
    static let radius: CGFloat = 16
    /// Inset chips.
    static let radiusSmall: CGFloat = 8

    static let hairline = Color.primary.opacity(0.08)
    static let inset = Color.primary.opacity(0.05)
    static let insetSelected = Color.primary.opacity(0.09)

    static let padding: CGFloat = 16
    static let spacing: CGFloat = 8

    static let title = Font.subheadline.weight(.semibold)
    static let body = Font.footnote
    static let bodyMedium = Font.footnote.weight(.medium)
    static let bodySemibold = Font.footnote.weight(.semibold)
    static let caption = Font.caption
    static let captionSecondary = Font.caption2

    static let pressScale: CGFloat = 0.97
}

extension View {
    /// Liquid Glass where available, a material elsewhere. One shape, no
    /// extra fill or stroke on top.
    @ViewBuilder
    func agentGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(AgentUI.glass(interactive: interactive, tint: tint), in: shape)
        } else if let tint {
            self.background(shape.fill(tint))
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    /// A group of glass controls that should merge and morph together.
    @ViewBuilder
    func agentGlassContainer(spacing: CGFloat = 8) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
extension AgentUI {
    static func glass(interactive: Bool, tint: Color?) -> Glass {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

// MARK: - Buttons

/// Press feedback only: a small scale, no colour change.
struct AgentPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? AgentUI.pressScale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A round glass button with one symbol.
struct GlassIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(AgentUI.bodySemibold)
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .agentGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(AgentPressStyle())
        .accessibilityLabel(label)
        .help(label)
    }
}

/// The one filled button on a surface: black with a white label in light
/// mode, white with a black label in dark mode. Everything else is glass.
struct ProminentFill: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .foregroundStyle(scheme == .dark ? Color.black : Color.white)
            .background(Capsule().fill(Color.primary))
    }
}

/// A capsule with a label: glass, or the monochrome fill when `prominent`.
struct GlassPillButton: View {
    let title: String
    let symbol: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let label = Label(title, systemImage: symbol)
                .font(AgentUI.bodySemibold)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .contentShape(Capsule())
            if prominent {
                label.modifier(ProminentFill())
            } else {
                label.foregroundStyle(.primary).agentGlass(in: Capsule(), interactive: true)
            }
        }
        .buttonStyle(AgentPressStyle())
    }
}

/// Full-width button for cards. Glass, or the monochrome fill for the one
/// primary action on a card.
struct AgentCardButton: View {
    let title: String
    var symbol: String? = nil
    var prominent = false
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let label = Group {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
            }
            .font(AgentUI.bodySemibold)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(Capsule())
            if prominent {
                label.modifier(ProminentFill())
            } else {
                label.foregroundStyle(destructive ? Color.red : Color.primary).agentGlass(in: Capsule(), interactive: true)
            }
        }
        .buttonStyle(AgentPressStyle())
    }
}

// MARK: - Symbols

/// An SF Symbol that draws itself on when it appears (iOS 26 / macOS 26;
/// a plain symbol before that). Give it an `.id` to redraw on change.
struct DrawOnSymbol: View {
    let name: String
    var font: Font = AgentUI.bodySemibold
    var color: Color = .primary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isUndrawn = true   // true = not yet drawn; the flip to false plays the draw-on

    var body: some View {
        Group {
            if #available(iOS 26.0, macOS 26.0, *), !reduceMotion {
                Image(systemName: name)
                    .symbolEffect(.drawOn.byLayer, isActive: isUndrawn)
            } else {
                Image(systemName: name)
            }
        }
        .font(font)
        .foregroundStyle(color)
        .onAppear {
            // Let the undrawn state commit first; the next-tick flip animates.
            DispatchQueue.main.async { isUndrawn = false }
        }
    }
}
