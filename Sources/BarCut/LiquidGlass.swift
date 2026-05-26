import SwiftUI

extension View {
    func liquidGlassCapsule(interactive: Bool = false) -> some View {
        modifier(LiquidGlassModifier(glass: .regular, shape: Capsule(), interactive: interactive))
    }

    func clearLiquidGlassCapsule(interactive: Bool = false) -> some View {
        modifier(LiquidGlassModifier(glass: .clear, shape: Capsule(), interactive: interactive))
    }

    func liquidGlassCircle(interactive: Bool = false) -> some View {
        modifier(LiquidGlassModifier(glass: .regular, shape: Circle(), interactive: interactive))
    }

    func liquidGlassRounded(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        modifier(LiquidGlassModifier(glass: .regular, shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), interactive: interactive))
    }
}

private struct LiquidGlassModifier<S: Shape>: ViewModifier {
    let glass: Glass
    let shape: S
    let interactive: Bool

    func body(content: Content) -> some View {
        content
            .glassEffect(glass.interactive(interactive), in: shape)
    }
}
