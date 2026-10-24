//
//  AgentUI.swift
//  Gepetto
//
//  The handful of values every Gepetto view draws from, and the glass
//  helper that wraps Liquid Glass on iOS 26 / macOS 26 and falls back to a
//  material below that. Chrome (the panel, buttons, cards, the toast) is
//  glass; content (the page, text, the timeline) is plain.
//
//  Every control keeps its 36 pt glass visual and carries a transparent
//  margin that brings the hit area to at least 44 by 44 pt.
//

import SwiftUI

enum AgentUI {
    /// Large floating surface: the panel.
    static let radiusLarge: CGFloat = 24
    /// Cards, the page region, buttons.
    static let radius: CGFloat = 16
    /// Inset chips.
    static let radiusSmall: CGFloat = 8
    /// The page region inside the panel: concentric with the panel's corner
    /// (panel radius minus the 10pt inset).
    static let radiusStage: CGFloat = 14

    static let hairline = Color.primary.opacity(0.08)
    static let inset = Color.primary.opacity(0.05)
    static let insetSelected = Color.primary.opacity(0.09)

    static let padding: CGFloat = 16
    static let spacing: CGFloat = 8

    /// The smallest hit area of any tappable control.
    static let hitTarget: CGFloat = 44
    /// The glass visual inside that hit area.
    static let controlSize: CGFloat = 36
    /// Transparent margin around a 36 pt control that makes it 44 pt to tap.
    static let hitMargin: CGFloat = (hitTarget - controlSize) / 2

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

    /// The soft drop shadow under a floating panel. Lighter in dark mode,
    /// where the surface behind is already dark.
    func agentPanelShadow() -> some View {
        modifier(AgentPanelShadow())
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

    /// Widens the tappable area of a control to at least 44 by 44 pt without
    /// touching what it draws. Apply after the glass, inside the button label.
    func agentHitTarget() -> some View {
        self
            .frame(minWidth: AgentUI.hitTarget, minHeight: AgentUI.hitTarget)
            .contentShape(Rectangle())
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

struct AgentPanelShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.14), radius: 28, x: 0, y: 14)
            .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.05), radius: 2, x: 0, y: 1)
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

/// A round glass button with one symbol. 36 pt of glass inside a 44 pt
/// hit area, so a row of them with zero stack spacing keeps 8 pt gaps.
struct GlassIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(AgentUI.bodySemibold)
                .foregroundStyle(.primary)
                .frame(width: AgentUI.controlSize, height: AgentUI.controlSize)
                .agentGlass(in: Circle(), interactive: true)
                .agentHitTarget()
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
/// The capsule is 36 pt tall; a 4 pt margin on every side makes it 44 pt
/// to tap.
struct GlassPillButton: View {
    let title: String
    var symbol: String? = nil
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let label = Group {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
            }
            .font(AgentUI.bodySemibold)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14)
            .frame(height: AgentUI.controlSize)
            Group {
                if prominent {
                    label.modifier(ProminentFill())
                } else {
                    label.foregroundStyle(.primary).agentGlass(in: Capsule(), interactive: true)
                }
            }
            .padding(.horizontal, AgentUI.hitMargin)
            .agentHitTarget()
        }
        .buttonStyle(AgentPressStyle())
    }
}

/// Full-width button for cards. Glass, or the monochrome fill for the one
/// primary action on a card. The capsule is 40 pt tall inside a 44 pt hit
/// area; disabled, it fades and stays monochrome.
struct AgentCardButton: View {
    let title: String
    var symbol: String? = nil
    var prominent = false
    var destructive = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            let label = Group {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
            }
            .font(AgentUI.bodySemibold)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            Group {
                if prominent {
                    label.modifier(ProminentFill())
                } else {
                    label.foregroundStyle(destructive ? Color.red : Color.primary).agentGlass(in: Capsule(), interactive: true)
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
            .agentHitTarget()
        }
        .buttonStyle(AgentPressStyle())
    }
}

// MARK: - Fields

/// The one text field style on a card: a plain field on an inset shape,
/// 44 pt tall so it is as easy to hit as a button.
struct AgentFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(AgentUI.body)
            .padding(.horizontal, 12)
            .frame(height: AgentUI.hitTarget)
            .background(RoundedRectangle(cornerRadius: AgentUI.radiusSmall, style: .continuous).fill(AgentUI.inset))
    }
}

extension View {
    func agentField() -> some View { modifier(AgentFieldStyle()) }
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
