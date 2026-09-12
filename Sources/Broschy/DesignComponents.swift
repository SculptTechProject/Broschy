import AppKit
import SwiftUI

private struct FlowReduceMotionKey: EnvironmentKey { static let defaultValue = false }
private struct FlowReduceTransparencyKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var flowReduceMotion: Bool {
        get { self[FlowReduceMotionKey.self] }
        set { self[FlowReduceMotionKey.self] = newValue }
    }
    var flowReduceTransparency: Bool {
        get { self[FlowReduceTransparencyKey.self] }
        set { self[FlowReduceTransparencyKey.self] = newValue }
    }
}

enum FlowMotion {
    static let selection = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.26)
    static let feedback = Animation.easeOut(duration: 0.14)
}

struct NotchShape: Shape {
    var cornerRadius: CGFloat = 20
    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.height / 2)
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: .init(x: rect.maxX, y: 0))
        path.addLine(to: .init(x: rect.maxX, y: rect.maxY - radius))
        path.addCurve(to: .init(x: rect.maxX - radius, y: rect.maxY),
                      control1: .init(x: rect.maxX, y: rect.maxY - radius * 0.38),
                      control2: .init(x: rect.maxX - radius * 0.38, y: rect.maxY))
        path.addLine(to: .init(x: radius, y: rect.maxY))
        path.addCurve(to: .init(x: 0, y: rect.maxY - radius),
                      control1: .init(x: radius * 0.38, y: rect.maxY),
                      control2: .init(x: 0, y: rect.maxY - radius * 0.38))
        path.closeSubpath()
        return path
    }
}

/// Compatibility backdrop for macOS versions before Liquid Glass.
struct NativeBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct PanelMaterial: View {
    let reduceTransparency: Bool
    var body: some View {
        if reduceTransparency {
            Ink.surface
        } else if #available(macOS 26.0, *) {
            Color.clear
        } else {
            NativeBackdrop()
        }
    }
}

struct PanelGlass: ViewModifier {
    let reduceTransparency: Bool
    let radius: CGFloat
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(!reduceTransparency ? .regular : .identity,
                                in: NotchShape(cornerRadius: radius))
        } else {
            content
        }
    }
}

/// Interior controls sit on the single glass panel instead of stacking glass.
struct ControlSurface: ViewModifier {
    var radius: CGFloat = 12
    @Environment(\.flowReduceTransparency) var reduceTransparency
    @Environment(\.colorScheme) var colorScheme
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Ink.raised, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        } else {
            content.background(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.35), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.55), lineWidth: 0.5))
        }
    }
}

struct FlowButtonStyle: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        FlowButtonSurface(label: configuration.label, pressed: configuration.isPressed, primary: primary)
    }
}

private struct FlowButtonSurface<Label: View>: View {
    let label: Label
    let pressed: Bool
    let primary: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) var enabled
    @Environment(\.flowReduceMotion) var reduceMotion
    @Environment(\.colorScheme) var colorScheme
    var body: some View {
        label
            .foregroundStyle(Ink.text)
            .background(Color.white.opacity(primary ? (colorScheme == .dark ? 0.04 : 0.20) : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .modifier(ControlSurface(radius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hovered && enabled ? (colorScheme == .dark ? 0.06 : 0.18) : 0)).allowsHitTesting(false))
            .scaleEffect(reduceMotion ? 1 : (pressed ? 0.975 : (hovered && enabled ? 1.008 : 1)))
            .opacity(enabled ? 1 : 0.48)
            .animation(reduceMotion ? nil : FlowMotion.feedback, value: pressed)
            .animation(reduceMotion ? nil : FlowMotion.feedback, value: hovered)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onHover { hovered = $0 }
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButtonSurface(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct QuietButtonSurface<Label: View>: View {
    let label: Label
    let pressed: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) var enabled
    @Environment(\.flowReduceMotion) var reduceMotion
    @Environment(\.colorScheme) var colorScheme
    var body: some View {
        label
            .background((colorScheme == .dark ? Color.white : Color.black)
                .opacity(enabled ? (pressed ? (colorScheme == .dark ? 0.10 : 0.08) : (hovered ? (colorScheme == .dark ? 0.055 : 0.035) : 0)) : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(pressed && enabled && !reduceMotion ? 0.94 : 1)
            .opacity(enabled ? 1 : 0.55)
            .animation(reduceMotion ? nil : FlowMotion.feedback, value: hovered)
            .animation(reduceMotion ? nil : FlowMotion.feedback, value: pressed)
            .onHover { hovered = $0 }
    }
}
