import SwiftUI
import AppKit

/// Cotes du rail de navigation (DESIGN.md §6).
enum Rail {
    static let margin: CGFloat = 12
    /// Hauteur de la barre d'outils : la zone de contenu et le rail commencent dessous.
    static let toolbarHeight: CGFloat = 52
    static let width: CGFloat = 84
    static let icon: CGFloat = 34
    /// Hauteur d'une section (icône + nom), écart entre deux, marge intérieure du rail.
    static let item: CGFloat = 62
    static let gap: CGFloat = 4
    static let pad: CGFloat = 8
    /// Marge entre la bulle de sélection et le bord du rail.
    static let bubbleInset: CGFloat = 6
    /// Place réservée au bord gauche du contenu pour le rail : le contenu ne bouge jamais.
    static var inset: CGFloat { margin + width + 12 }
    static func height(_ n: Int) -> CGFloat { CGFloat(n) * item + CGFloat(max(0, n - 1)) * gap + 2 * pad }
    /// Bords haut et bas de la section `i` dans le rail.
    static func span(_ i: Int) -> (CGFloat, CGFloat) { let y = pad + CGFloat(i) * (item + gap); return (y, y + item) }
}

/// Icône d'une section : image du thème, sinon SF Symbol.
struct SectionIcon: View {
    let section: AppSection
    let size: CGFloat
    var body: some View {
        if let i = ThemePack.shared.icon(section) {
            Image(nsImage: i).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: section.symbol).font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(Palette.ink)
                .frame(width: size, height: size)
        }
    }
}

/// Bulle de sélection (DESIGN.md §11, §12) : ses deux bords `lo` et `hi` sur l'axe du mouvement sont animés ensemble par un ressort SwiftUI
/// (aucun étirement, aucune minuterie) et, à chaque image, bornés au contenant : un dépassement l'écrase contre le bord au lieu de le
/// franchir. Une bulle ne sort jamais de son contenant.
struct BubbleSpan: Animatable, ViewModifier {
    var lo: CGFloat
    var hi: CGFloat
    let vertical: Bool
    /// Longueur du contenant sur l'axe du mouvement.
    let length: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(lo, hi) }
        set { lo = newValue.first; hi = newValue.second }
    }

    static func clamp(_ lo: CGFloat, _ hi: CGFloat, length: CGFloat) -> (lo: CGFloat, hi: CGFloat) {
        let a = min(max(lo, 0), length)
        return (a, max(min(hi, length), a))
    }

    func body(content: Content) -> some View {
        let c = Self.clamp(lo, hi, length: length)
        if vertical {
            content.frame(height: max(0, c.hi - c.lo)).offset(y: c.lo).frame(maxHeight: .infinity, alignment: .top)
        } else {
            content.frame(width: max(0, c.hi - c.lo)).offset(x: c.lo).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension Nav {
    /// Section voisine (flèches, molette) : bornée aux deux bouts, pas de boucle.
    func step(_ d: Int) {
        let ss = visibleSections
        guard let i = ss.firstIndex(of: section), ss.indices.contains(i + d) else { return }
        select(ss[i + d])
    }
}

/// Rail de navigation : une capsule de verre permanente au bord gauche (marge 12 pt), une icône de 34 pt et son nom dessous pour chaque
/// section, toujours visibles. Clic immédiat ; au survol, sans délai, l'icône survolée grossit légèrement (1,08, `Motion.detail`).
/// La bulle de sélection en verre glisse d'une section à l'autre avec `Motion.section` et reste dans le rail. ⌘1-⌘6 (menu « Aller »),
/// flèches ↑↓ (après un clic sur le rail) et molette (une section par cran ; pavé tactile : 36 pt) changent aussi de section.
struct NavRail: View {
    let nav = Nav.shared
    @Environment(\.opaqueSurfaces) private var reduceTransparency
    @Local private var hovered: AppSection?
    @Local private var span: (lo: CGFloat, hi: CGFloat) = Rail.span(0)
    @Local private var monitor: Any?
    @Local private var scrollAcc: CGFloat = 0
    @FocusState private var focused: Bool

    var body: some View {
        let ss = nav.visibleSections
        let H = Rail.height(ss.count)
        let shape = RoundedRectangle(cornerRadius: Radius.rail, style: .continuous)
        VStack(spacing: Rail.gap) {
            ForEach(ss) { s in item(s) }
        }
        .padding(.vertical, Rail.pad)
        .frame(width: Rail.width, height: H)
        .background(alignment: .top) {
            // Bulle sous les icônes, bornée à l'intérieur du rail.
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(reduceTransparency ? AnyShapeStyle(Palette.skyDeep) : AnyShapeStyle(Palette.aqua.opacity(0.16)))
                .glassSurface(reduceTransparency ? .identity : .regular.tint(Palette.aqua.opacity(0.4)).interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, Rail.bubbleInset)
                .modifier(BubbleSpan(lo: span.lo, hi: span.hi, vertical: true, length: H))
                .allowsHitTesting(false)
        }
        .background { if reduceTransparency { shape.fill(Palette.nightBlue) } }
        .glassSurface(reduceTransparency ? .identity : .regular.tint(Palette.sky.opacity(0.12)), in: shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.28), lineWidth: 1).allowsHitTesting(false))
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.upArrow) { nav.step(-1); return .handled }
        .onKeyPress(.downArrow) { nav.step(1); return .handled }
        .onHover { on in if on { startMonitor() } else { stopMonitor(); hovered = nil } }
        .onAppear { place(animated: false) }
        .onChange(of: nav.section) { _, _ in place(animated: true) }
        .onChange(of: nav.live) { _, live in if !live { stopMonitor() } }
        .onDisappear { stopMonitor() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, Rail.margin)
        .padding(.top, Rail.toolbarHeight).padding(.bottom, Rail.margin)   // centré dans la zone de contenu, sous la barre d'outils
    }

    func item(_ s: AppSection) -> some View {
        let on = s == nav.section
        return Button { focused = true; nav.select(s) } label: {
            VStack(spacing: 3) {
                SectionIcon(section: s, size: Rail.icon)
                    .scaleEffect(hovered == s ? 1.08 : 1)
                    .animation(Motion.detail, value: hovered == s)
                Text(s.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(on ? Palette.ink : Palette.inkSecondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(width: Rail.width - 2 * Rail.bubbleInset, height: Rail.item)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in if h { hovered = s } else if hovered == s { hovered = nil } }
        .help(s.title)
        .accessibilityLabel(s.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// La bulle va sur la section affichée (ressort natif : interrompue, elle repart de sa position et de sa vitesse du moment).
    private func place(animated: Bool) {
        let i = nav.visibleSections.firstIndex(of: nav.section) ?? 0
        let t = Rail.span(i)
        if animated { withAnimation(Motion.section) { span = t } } else { span = t }
    }

    // MARK: molette (souris : une section par cran ; pavé tactile : une section par 36 pt de défilement, inertie ignorée)

    private func startMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            let precise = e.hasPreciseScrollingDeltas, dy = e.scrollingDeltaY, momentum = !e.momentumPhase.isEmpty
            MainActor.assumeIsolated {
                if momentum { return }
                if precise {
                    scrollAcc += dy
                    guard abs(scrollAcc) >= 36 else { return }
                    Nav.shared.step(scrollAcc > 0 ? -1 : 1); scrollAcc = 0
                } else if dy != 0 {
                    Nav.shared.step(dy > 0 ? -1 : 1)
                }
            }
            return nil
        }
    }

    private func stopMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        scrollAcc = 0
    }
}

/// Commandes de menu ⌘1 à ⌘6 : une par section affichée.
struct NavCommands: Commands {
    let nav = Nav.shared
    var body: some Commands {
        CommandMenu("Aller") {
            ForEach(Array(nav.visibleSections.enumerated()), id: \.element) { i, s in
                Button(s.title) { Router.shared.section = s; MainWindow.shared.show() }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
        }
    }
}

/// Commandes que SwiftUI ne crée pas pour la fenêtre principale (un `NSWindow` géré par zerOS, pas une scène) : Fichier > Fermer (⌘W),
/// Présentation > plein écran (⌃⌘F, intitulé selon l'état), et Aide sans « Aide zerOS » (pas de livre d'aide : macOS répondait « Aide
/// non disponible »), le champ de recherche de macOS restant dans le menu.
struct WindowCommands: Commands {
    let nav = Nav.shared
    var body: some Commands {
        // À la place de Fermer / Tout fermer de SwiftUI (sans raccourci pour cette fenêtre-ci).
        CommandGroup(replacing: .saveItem) {
            Button("Fermer") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w")
        }
        CommandGroup(after: .toolbar) {
            Button(nav.fullScreen ? "Quitter le mode plein écran" : "Passer en mode plein écran") { MainWindow.shared.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [.command, .control])
        }
        CommandGroup(replacing: .help) { }
    }
}

