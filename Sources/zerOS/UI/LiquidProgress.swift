import SwiftUI
import AppKit

/// Chargements en verre (DESIGN.md §14) : du vrai Liquid Glass natif posé sur des couleurs vives, aucune forme de verre dessinée.
/// Animés seulement pendant un chargement visible : fenêtre fermée ou cachée, ou « Réduire les animations » → image fixe, aucun calcul.
private struct LiquidActive<Content: View>: View {
    @Environment(\.pageState) private var page
    @Environment(\.tabState) private var tab
    @ViewBuilder var content: (_ active: Bool) -> Content
    var body: some View { LiquidGate(page: page ?? .always, tab: tab ?? .always, content: content) }
}

/// Actif seulement si la fenêtre est à l'écran et la page (et la sous-section) qui le contient affichée.
private struct LiquidGate<Content: View>: View {
    let nav = Nav.shared
    @ObservedObject var page: PageState
    @ObservedObject var tab: PageState
    let content: (_ active: Bool) -> Content
    var body: some View { content(nav.live && nav.visible && page.shown && tab.shown && !Motion.reduced) }
}

/// Dégradé vif des chargements : aqua → bleu → violet.
private let liquidGradient = LinearGradient(colors: [Palette.aqua, Palette.sky, Palette.violet], startPoint: .leading, endPoint: .trailing)

/// Chargement indéterminé : trois gouttes de verre teinté qui tournent, se rapprochent jusqu'à fusionner puis se séparent
/// (fusion native des formes de verre proches dans un `GlassEffectContainer`).
struct LiquidRing: View {
    var size: CGFloat = 64
    var body: some View {
        // Deux vues distinctes : inactif, la vue animée quitte la hiérarchie et ses animations répétées avec elle (remettre la valeur
        // sans animation ne les arrête pas : les animations SwiftUI s'additionnent, mesuré 58 % de CPU avec des gouttes « arrêtées »).
        LiquidActive { active in
            if active { LiquidDrops(size: size, animated: true) } else { LiquidDrops(size: size, animated: false) }
        }
            .shadow(color: Palette.nightBlue.opacity(0.35), radius: size * 0.08, y: size * 0.04)
            .frame(width: size, height: size)
            .accessibilityLabel("Chargement")
    }
}

/// Les gouttes tournent (un tour en 2,9 s) et leur orbite respire (1,85 s) : proches elles fusionnent, éloignées elles se séparent.
/// Animations SwiftUI répétées, calculées par SwiftUI à chaque image de l'écran (120 Hz), plus de minuterie à 30 images/s.
private struct LiquidDrops: View {
    let size: CGFloat
    let animated: Bool
    @Environment(\.opaqueSurfaces) private var reduceTransparency
    @Local private var turn = false
    @Local private var open = false

    var body: some View {
        let drop = size * 0.4, r = size * 0.27 * (open ? 1 : 0.15)
        let colors = [Palette.aqua, Palette.sky, Palette.violet]
        ZStack {
            ForEach(0..<3, id: \.self) { k in
                let a = Double(k) * 2 * .pi / 3
                Circle()
                    .fill(colors[k].opacity(reduceTransparency ? 1 : 0.55))
                    .frame(width: drop, height: drop)
                    .glassSurface(reduceTransparency ? .identity : .regular.tint(colors[k].opacity(0.7)), in: Circle())
                    .offset(x: r * CGFloat(cos(a)), y: r * CGFloat(sin(a)))
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(turn ? 360 : 0))
        .glassGroup(spacing: size * 0.22)
        .onAppear {
            guard animated else { return }
            withAnimation(.linear(duration: 2.9).repeatForever(autoreverses: false)) { turn = true }
            withAnimation(.easeInOut(duration: 1.85).repeatForever(autoreverses: true)) { open = true }
        }
    }
}

/// Barre de progression : piste vive (aqua → bleu → violet) sous un tube de verre épais ; à la tête du remplissage, une lentille de verre
/// qui grossit la couleur sous elle (copie agrandie du dégradé masquée dans le cercle), avec reflet sur le bord. Rien ne bouge au repos :
/// seule la lentille glisse quand la valeur change.
struct LiquidTube: View {
    /// 0 à 1.
    let value: Double
    var height: CGFloat = 18
    @Environment(\.opaqueSurfaces) private var reduceTransparency

    var body: some View {
        let v = min(1, max(0, value))
        let lens = height * 1.55, track = height * 0.56
        GeometryReader { g in
            let W = g.size.width, mid = g.size.height / 2
            let head = min(W - lens / 2, max(lens / 2, W * v))
            ZStack(alignment: .topLeading) {
                // Piste vide puis remplissage vif.
                Capsule().fill(Color.white.opacity(0.16))
                    .frame(width: W - (height - track), height: track)
                    .position(x: W / 2, y: mid)
                filled(W, head: head, track: track).position(x: W / 2, y: mid)
                // Tube de verre épais par-dessus la piste.
                Color.clear.frame(width: W, height: height)
                    .glassSurface(reduceTransparency ? .identity : .clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.75))
                    .position(x: W / 2, y: mid)
                // Lentille : la couleur sous elle, agrandie 1,45 fois, dans un cercle de verre.
                filled(W, head: head, track: track)
                    .scaleEffect(1.45, anchor: UnitPoint(x: head / max(1, W), y: 0.5))
                    .position(x: W / 2, y: mid)
                    .mask { Circle().frame(width: lens, height: lens).position(x: head, y: mid) }
                lensGlass(lens).position(x: head, y: mid)
            }
            .animation(Motion.detail, value: v)
        }
        .frame(height: lens)
        .frame(maxWidth: .infinity)
        .accessibilityElement().accessibilityLabel("Progression").accessibilityValue(Fmt.percent(v * 100))
    }

    /// Remplissage vif jusqu'à la tête (dégradé sur toute la largeur : la couleur dit où l'on en est).
    private func filled(_ W: CGFloat, head: CGFloat, track: CGFloat) -> some View {
        let inner = W - (height - track)
        return liquidGradient
            .frame(width: inner, height: track)
            .mask(alignment: .leading) { Capsule().frame(width: max(track, head - (height - track) / 2), height: track) }
    }

    private func lensGlass(_ d: CGFloat) -> some View {
        Color.clear.frame(width: d, height: d)
            .glassSurface(reduceTransparency ? .identity : .clear, in: Circle())
            .overlay {
                // Reflet spéculaire : arc blanc en haut à gauche, liseré clair sur tout le bord.
                Circle().strokeBorder(AngularGradient(colors: [.white.opacity(0.9), .white.opacity(0.15), .white.opacity(0.5), .white.opacity(0.15), .white.opacity(0.9)],
                                                      center: .center, angle: .degrees(-135)), lineWidth: 1.2)
                Ellipse().fill(LinearGradient(colors: [.white.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
                    .frame(width: d * 0.42, height: d * 0.2).offset(x: -d * 0.12, y: -d * 0.26)
            }
            .shadow(color: Palette.nightBlue.opacity(0.35), radius: 4, y: 2)
            .allowsHitTesting(false)
    }
}

/// Fenêtre de contrôle visuel (`--demo-liquid`, jamais utilisée en fonctionnement normal).
@MainActor
enum LiquidDemo {
    static var window: NSWindow?
    static func show() {
        let v = ZStack {
            LinearGradient(colors: [Palette.skyDeep, Palette.aqua], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 26) {
                HStack(spacing: 28) { LiquidRing(size: 18); LiquidRing(size: 32); LiquidRing(size: 72); LiquidRing(size: 110) }
                VStack(spacing: 14) { LiquidTube(value: 0.12); LiquidTube(value: 0.55); LiquidTube(value: 0.95) }.padding(.horizontal, 30)
            }
        }
        .frame(width: 560, height: 380)
        let w = NSWindow(contentViewController: NSHostingController(rootView: v))
        w.title = "Chargements liquides"; w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        window = w
        Nav.shared.visible = true
    }
}
