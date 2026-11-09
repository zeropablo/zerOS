import SwiftUI

/// Seule surface de verre de zerOS. Sur macOS 26 et plus : exactement `.glassEffect` / `GlassEffectContainer` (Liquid Glass).
/// Sous macOS 26 (ou avec `--force-legacy-glass`, pour les captures) : verre dépoli fin (matériau système le plus léger) de même forme,
/// léger voile clair, teinte par-dessus, reflet doux en haut, liseré lumineux éclairé par le haut et ombre légère : clair et aérien.
enum GlassMode {
    /// Vrai sous macOS 26, ou si `--force-legacy-glass` est passé au lancement.
    static let legacy: Bool = {
        if #available(macOS 26, *) { return CommandLine.arguments.contains("--force-legacy-glass") }
        return true
    }()
}

/// Description d'un verre, indépendante de l'API Liquid Glass.
struct GlassLook {
    /// `regular` : verre courant ; `clear` : verre très transparent (dépoli : même matériau fin, voile plus léger).
    enum Kind { case regular, clear }
    var kind: Kind = .regular
    var tint: Color? = nil
    var interactive = false
    /// Aucun verre (`.identity`) : « Réduire la transparence ».
    var off = false

    static let regular = GlassLook()
    static let clear = GlassLook(kind: .clear)
    static let identity = GlassLook(off: true)
    func tint(_ c: Color) -> GlassLook { var g = self; g.tint = c; return g }
    func interactive(_ on: Bool = true) -> GlassLook { var g = self; g.interactive = on; return g }

    @available(macOS 26, *)
    var glass: Glass {
        if off { return .identity }
        var g: Glass = kind == .clear ? .clear : .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

private struct GlassSurface<S: Shape>: ViewModifier {
    let look: GlassLook
    let shape: S
    func body(content: Content) -> some View {
        if #available(macOS 26, *), !GlassMode.legacy {
            content.glassEffect(look.glass, in: shape)
        } else {
            content.background {
                if !look.off {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Color.white.opacity(look.kind == .clear ? 0.05 : 0.10))
                        if let t = look.tint { shape.fill(t) }
                        // Reflet : lumière douce venue du haut, qui s'éteint avant le milieu.
                        shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0.16), location: 0), .init(color: .white.opacity(0), location: 0.45)],
                                                  startPoint: .top, endPoint: .bottom))
                        shape.stroke(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.22), .white.opacity(0.35)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    }
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                }
            }
        }
    }
}

private struct GlassGroup: ViewModifier {
    let spacing: CGFloat?
    func body(content: Content) -> some View {
        if #available(macOS 26, *), !GlassMode.legacy {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

private struct GlassButtons: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *), !GlassMode.legacy {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}

extension View {
    /// Verre de zerOS (remplace tout `.glassEffect(_:in:)` direct).
    func glassSurface<S: Shape>(_ look: GlassLook = .regular, in shape: S) -> some View { modifier(GlassSurface(look: look, shape: shape)) }
    /// Groupe de verres qui fusionnent (remplace `GlassEffectContainer`).
    func glassGroup(spacing: CGFloat? = nil) -> some View { modifier(GlassGroup(spacing: spacing)) }
    /// Boutons en verre (remplace `.buttonStyle(.glass)`) ; sous macOS 26 : boutons système en capsule.
    func glassButtons() -> some View { modifier(GlassButtons()) }
}
