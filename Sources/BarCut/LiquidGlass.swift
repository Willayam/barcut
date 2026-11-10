import SwiftUI

extension View {
    func liquidGlassCapsule(interactive: Bool = false) -> some View {
        modifier(LiquidGlassModifier(glass: .regular, shape: Capsule(), interactive: interactive))
    }

    /// Keeps white labels readable over any thumbnail, light or dark.
    func darkLiquidGlassCapsule() -> some View {
        modifier(LiquidGlassModifier(glass: .regular.tint(.black.opacity(0.45)), shape: Capsule(), interactive: false))
    }

    func liquidGlassCircle(interactive: Bool = false) -> some View {
        modifier(LiquidGlassModifier(glass: .regular, shape: Circle(), interactive: interactive))
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
