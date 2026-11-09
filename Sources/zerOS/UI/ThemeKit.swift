import SwiftUI
import AppKit
import ImageIO

/// Couleurs du thème (DESIGN.md §3). Seules couleurs codées en dur de l'app.
enum Palette {
    static let sky = Color(red: 0x2E / 255, green: 0x8B / 255, blue: 1)
    static let skyDeep = Color(red: 0x0A / 255, green: 0x4F / 255, blue: 0xD6 / 255)
    static let aqua = Color(red: 0x3F / 255, green: 0xD8 / 255, blue: 1)
    static let grass = Color(red: 0x7E / 255, green: 0xD3 / 255, blue: 0x21 / 255)
    static let grassDeep = Color(red: 0x3F / 255, green: 0xA6 / 255, blue: 0x0F / 255)
    static let warn = Color(red: 1, green: 0xB0 / 255, blue: 0x20 / 255)
    static let alert = Color(red: 1, green: 0x4D / 255, blue: 0x4F / 255)
    static let nightBlue = Color(red: 0x06 / 255, green: 0x20 / 255, blue: 0x4A / 255)
    /// Couleurs vives : chargements (dégradé aqua → sky → violet) et catégories de l'arborescence.
    static let violet = Color(red: 0x8A / 255, green: 0x5C / 255, blue: 1)
    static let ember = Color(red: 1, green: 0x7A / 255, blue: 0x1A / 255)
    static let sun = Color(red: 1, green: 0xD4 / 255, blue: 0x3B / 255)
    static let silver = Color(red: 0xAE / 255, green: 0xB9 / 255, blue: 0xC8 / 255)
    static let ink = Color.white
    static let inkSecondary = Color.white.opacity(0.75)
}

/// Typographie (DESIGN.md §4) : SF Rounded semi-gras pour titres et chiffres, police système ailleurs.
extension Font {
    static func themeTitle(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
}

/// Échelle typographique (DESIGN.md §4) : les seules tailles de texte des pages.
enum Typo {
    /// Grand titre d'une page d'accueil de module ou de fin (« C'est fait ! »).
    static let hero = Font.themeTitle(28)
    /// Titre de page (nom du Mac, nom d'une app).
    static let pageTitle = Font.themeTitle(24)
    /// Chiffre clé d'une tuile ou d'un résultat.
    static let value = Font.themeTitle(22)
    /// Titre d'un bloc dans une page (« Actions », « Historique »…).
    static let sectionTitle = Font.themeTitle(17)
    /// Titre de tuile, de panneau, de ligne importante.
    static let headline = Font.system(size: 13, weight: .semibold)
    /// Texte secondaire, détails.
    static let detail = Font.callout
    /// Pied de tuile, légendes, petites mentions.
    static let caption = Font.caption
}

/// Espacements (DESIGN.md §8) : marges de page, intérieur des panneaux, écart de grille.
enum Space {
    /// Marge extérieure d'une page.
    static let page: CGFloat = 20
    /// Intérieur d'un panneau ou d'une tuile.
    static let panel: CGFloat = 16
    /// Écart entre tuiles, colonnes, panneaux.
    static let gap: CGFloat = 12
    /// Écart vertical entre blocs d'une page.
    static let block: CGFloat = 16
}

/// Tuile (DESIGN.md §8) : hauteur fixe, mêmes marges, toujours trois lignes : titre + état / valeur / pied (jauge facultative au-dessus du pied,
/// sa place est gardée même absente pour que toutes les tuiles s'alignent). Le pied est toujours un texte utile, jamais un tiret seul.
struct Tile: View {
    let title: String
    let value: String
    let footer: String
    /// Pastille et libellé d'état (vert / orange / rouge), ou à défaut un symbole.
    var state: (label: String, color: Color)? = nil
    var symbol: String? = nil
    var gauge: Double? = nil
    static let height: CGFloat = 124

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let state { StatePill(color: state.color, size: 10) }
                else if let symbol { Image(systemName: symbol).font(Typo.headline).foregroundStyle(Palette.aqua) }
                Text(title).font(Typo.headline).lineLimit(1)
                Spacer(minLength: 4)
                if let state { Text(state.label).font(Typo.caption).foregroundStyle(Palette.inkSecondary) }
            }
            Spacer(minLength: 6)
            Text(value).font(Typo.value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 6)
            ZStack(alignment: .leading) {
                if let gauge {
                    GeometryReader { g in
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(state?.color ?? Palette.aqua).frame(width: g.size.width * min(1, max(0, gauge)))
                    }
                }
            }
            .frame(height: 6)
            .padding(.bottom, 6)
            Text(footer).font(Typo.caption).foregroundStyle(Palette.inkSecondary).lineLimit(1).truncationMode(.tail).help(footer)
        }
        .padding(Space.panel)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .topLeading)
        .themePanel()
        .contentShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        // VoiceOver : une tuile = un élément (« Disque interne, Bon, 49,5 Go libres, sur 245 Go »), pas cinq morceaux.
        .accessibilityElement(children: .combine)
    }
}

/// Réglages de lisibilité d'une section (theme.json, DESIGN.md §5).
struct SectionStyle {
    var overlay = 0.15, glassTint = 0.15, toolbarScrim = true
}

/// Pack de thème embarqué (`Contents/Resources/Theme`). Fichier manquant → repli (dégradé bleu, SF Symbols).
@MainActor
final class ThemePack {
    static let shared = ThemePack()
    let root: URL? = {
        let u = Bundle.main.resourceURL?.appendingPathComponent("Theme")
        return u.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }()
    private(set) lazy var styles: [String: SectionStyle] = {
        var out: [String: SectionStyle] = [:]
        guard let root, let d = try? Data(contentsOf: root.appendingPathComponent("theme.json")),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let s = j["sections"] as? [String: [String: Any]] else { return out }
        for (k, v) in s {
            out[k] = SectionStyle(overlay: (v["overlay"] as? Double) ?? 0.15, glassTint: (v["glassTint"] as? Double) ?? 0.15,
                                  toolbarScrim: (v["toolbarScrim"] as? Bool) ?? true)
        }
        return out
    }()
    private var icons: [String: NSImage] = [:]

    func style(_ s: AppSection) -> SectionStyle { styles[s.themeFolder] ?? SectionStyle() }
    func file(_ s: AppSection, _ name: String) -> URL? {
        guard let u = root?.appendingPathComponent(s.themeFolder).appendingPathComponent(name),
              FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }
    /// Icône de section (192 px, pour les 96 pt de la roue agrandie), gardée en cache : six petites images, rendues à la fermeture.
    func icon(_ s: AppSection) -> NSImage? {
        if let i = icons[s.rawValue] { return i }
        guard let u = file(s, "icon.png"), let cg = Self.decode(u, maxPixel: 192) else { return nil }
        let i = NSImage(cgImage: cg, size: NSSize(width: 96, height: 96))
        icons[s.rawValue] = i
        return i
    }
    var hasBackgrounds: Bool { root != nil }
    func releaseIcons() { icons = [:] }

    /// Décodage ImageIO à la taille voulue (jamais l'image pleine taille en mémoire).
    /// `space` : espace colorimétrique de l'écran ; l'image y est convertie ici, hors du fil principal.
    nonisolated static func decode(_ url: URL, maxPixel: Int, space: CGColorSpace? = nil) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        // Redessiné en BGRA dans l'espace colorimétrique de l'écran, ici, hors du fil principal : sinon Core Animation convertit le JPEG
        // (RVB 24 bits, profil ICC) sur le fil principal à l'affichage de chaque fond, 20 à 50 ms figées au changement de section.
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: space ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }
}

extension AppSection {
    var themeFolder: String {
        switch self {
        case .today: "aujourdhui"
        case .storage: "stockage"
        case .apps: "apps"
        case .health: "sante"
        case .journal: "journal"
        }
    }
}

/// Fond de la section affichée : un seul décodé à la fois (plus le précédent pendant le fondu de 0,35 s), libéré ensuite.
@MainActor
final class ThemeBackgrounds: ObservableObject {
    static let shared = ThemeBackgrounds()
    struct Layer: Identifiable { let id = UUID(); let sharp: CGImage?; let blur: CGImage?; let pixels: Int; let space: String? }
    @Published private(set) var layers: [Layer] = []
    @Published var size: CGSize = .zero
    private var section: AppSection?
    private var task: Task<Void, Never>?
    /// Échelle et espace colorimétrique de l'écran de la fenêtre (jamais `NSScreen.main`, l'écran qui a le clavier : avec un Retina et un
    /// écran externe, la fenêtre peut être sur l'autre). Posés par `MainWindow` à l'ouverture et à chaque changement d'écran ou d'échelle.
    private(set) var scale: CGFloat = 2
    private var space: CGColorSpace?

    /// La fenêtre a changé d'écran (ou l'écran d'échelle / de profil) : fond redécodé en arrière-plan pour le nouvel écran, l'ancien reste
    /// affiché jusqu'à l'arrivée du nouveau (fondu enchaîné).
    func screen(_ s: NSScreen?) {
        guard let s else { return }
        let sp = s.colorSpace?.cgColorSpace
        guard s.backingScaleFactor != scale || sp?.name != space?.name else { return }
        scale = s.backingScaleFactor; space = sp
        if let sec = section, size != .zero { show(sec, size: size, scale: scale) }
    }

    var current: Layer? { layers.last }

    func show(_ s: AppSection, size: CGSize, scale: CGFloat) {
        let px = Int(max(size.width, size.height) * scale)
        guard px > 0, ThemePack.shared.hasBackgrounds else { return }
        // Même section et taille de décodage encore suffisante : rien à recalculer.
        if section == s, let c = current, c.pixels * 10 >= px * 9, c.space == space?.name as String? { return }
        section = s
        let a = ThemePack.shared.file(s, "background.jpg"), b = ThemePack.shared.file(s, "background-blur.jpg")
        task?.cancel()
        let space = self.space
        task = Task { [weak self] in
            let (sharp, blur) = await Task.detached(priority: .userInitiated) {
                (a.flatMap { ThemePack.decode($0, maxPixel: px, space: space) }, b.flatMap { ThemePack.decode($0, maxPixel: px, space: space) })
            }.value
            guard let self, !Task.isCancelled, self.section == s else { return }
            let layer = Layer(sharp: sharp, blur: blur, pixels: px, space: space?.name as String?)
            let old = self.layers.last
            // L'ancien fond est rendu à la fin du fondu (fin de l'animation, pas une minuterie).
            withAnimation(Motion.background) { self.layers = (old.map { [$0] } ?? []) + [layer] } completion: { [weak self] in
                guard let self, self.layers.last?.id == layer.id else { return }
                self.layers = Array(self.layers.suffix(1))
            }
        }
    }

    /// Fenêtre fermée : toutes les images sont libérées.
    func release() {
        task?.cancel()
        layers = []; section = nil
    }
}

private struct GlassTintKey: EnvironmentKey { static let defaultValue = 0.15 }
extension EnvironmentValues {
    var themeGlassTint: Double { get { self[GlassTintKey.self] } set { self[GlassTintKey.self] = newValue } }
}

/// Image de fond posée directement comme contenu d'un calque (remplissage centré) : pas de cache SwiftUI, libérée avec la vue.
private struct LayerImage: NSViewRepresentable {
    let image: CGImage
    func makeNSView(context: Context) -> NSView {
        let v = NSView(); v.wantsLayer = true
        v.layer?.contentsGravity = .resizeAspectFill; v.layer?.masksToBounds = true
        v.layer?.contents = image
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
    static func dismantleNSView(_ v: NSView, coordinator: ()) { v.layer?.contents = nil }
}

private func fill(_ img: CGImage, _ size: CGSize) -> some View {
    LayerImage(image: img).frame(width: size.width, height: size.height)
}

/// Voile de lisibilité (bleu nuit, noir en mode sombre) et dégradé sous la barre d'outils ; posé sur chaque fond.
struct ThemeVeil: View {
    @Environment(\.opaqueSurfaces) private var reduceTransparency
    let section: AppSection
    var body: some View {
        let st = ThemePack.shared.style(section)
        let sysDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        ZStack {
            Palette.nightBlue.opacity(reduceTransparency ? 0.5 : st.overlay)
            if sysDark { Color.black.opacity(0.35) }
            if st.toolbarScrim {
                LinearGradient(colors: [Palette.nightBlue.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 110).frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

/// Couches communes à toute la fenêtre : fond net plein cadre, voile de lisibilité, dégradé sous la barre d'outils.
struct ThemeBackdrop: View {
    @ObservedObject var bg = ThemeBackgrounds.shared
    @Environment(\.opaqueSurfaces) private var reduceTransparency
    let section: AppSection

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.skyDeep, Palette.aqua], startPoint: .top, endPoint: .bottom)
            ForEach(bg.layers) { l in
                if let s = l.sharp { fill(s, bg.size).transition(.opacity) }
            }
            ThemeVeil(section: section)
        }
        .frame(width: bg.size.width, height: bg.size.height)
        .allowsHitTesting(false)
    }
}

/// Fond flouté, limité à la zone de contenu (se place derrière la colonne de détail).
struct ThemeBlurInContent: View {
    @ObservedObject var bg = ThemeBackgrounds.shared
    let section: AppSection
    var body: some View {
        GeometryReader { g in
            let f = g.frame(in: .named("themeWindow"))
            ZStack {
                ForEach(bg.layers) { l in
                    if let b = l.blur { fill(b, bg.size).transition(.opacity) }
                }
                ThemeVeil(section: section)
            }
            .frame(width: bg.size.width, height: bg.size.height)
            .offset(x: -f.minX, y: -f.minY)
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .clipped()
        }
        .allowsHitTesting(false)
    }
}

/// Panneau de contenu (DESIGN.md §8) : verre natif teinté sur un fond bleu nuit, coins 26 pt, liseré blanc 25 %.
/// Le fond bleu nuit (proportionnel à la teinte de la section) garde le texte blanc lisible sur un ciel clair.
struct ThemePanelBackground: ViewModifier {
    @Environment(\.themeGlassTint) private var tint
    @Environment(\.opaqueSurfaces) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        content
            .background { shape.fill(Palette.nightBlue.opacity(reduceTransparency ? 1 : (GlassMode.legacy ? min(0.3, tint * 0.6) : min(0.6, tint * 1.2)))) }
            .glassSurface(reduceTransparency ? .identity : .regular.tint(Palette.sky.opacity(tint)), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
    }
}

extension View {
    /// Fait de cette zone un panneau de verre du thème (listes et colonnes qui ne sont pas des GroupBox).
    func themePanel() -> some View { modifier(ThemePanelBackground()) }

    /// Ligne de liste ou de tableau en rangée arrondie (DESIGN.md §8) : fond blanc léger, pas de séparateur.
    func themeRow() -> some View {
        listRowBackground(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(Color.white.opacity(0.07)).padding(.vertical, 1.5).padding(.horizontal, 6))
            .listRowSeparator(.hidden)
    }
}

extension View {
    /// DESIGN.md §12 : aucun texte ni liste coupés net par un bord arrondi. Une zone qui défile s'estompe sur `size` points en haut et en bas.
    func scrollEdgeFade(_ size: CGFloat = 16) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: size)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: size)
            }
        }
    }

    /// Ligne d'une liste paresseuse (`LazyVStack`, sans vue AppKit par ligne) : même rangée arrondie que `themeRow()`, plus claire si choisie.
    func lazyRow(selected: Bool = false) -> some View {
        padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(Color.white.opacity(selected ? 0.2 : 0.07)))
            .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .padding(.horizontal, 6).padding(.vertical, 1.5)
    }
}

struct ThemePanelStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label.font(Typo.headline)
            configuration.content
        }
        .padding(Space.panel)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themePanel()
    }
}

/// Bouton d'action principal (DESIGN.md §8) : verre aqua, reflet blanc fixe, capsule.
struct ThemePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.opaqueSurfaces) private var reduceTransparency
    func makeLabel(_ c: Configuration) -> some View { c.label }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 20).padding(.vertical, 9)
            .background { if reduceTransparency { Capsule().fill(Palette.skyDeep) } }
            .glassSurface(reduceTransparency ? .identity : .regular.tint(Palette.aqua.opacity(0.75)).interactive(), in: Capsule())
            .overlay(alignment: .top) {
                Capsule().fill(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom))
                    .frame(height: 16).padding(.horizontal, 10).padding(.top, 2).allowsHitTesting(false)
            }
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
    }
}

/// Pastille d'état (DESIGN.md §8) : disque grass / warn / alert avec reflet fixe.
struct StatePill: View {
    let color: Color
    var size: CGFloat = 12
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay(alignment: .top) {
                Ellipse().fill(LinearGradient(colors: [.white.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
                    .frame(width: size * 0.6, height: size * 0.4).padding(.top, size * 0.08)
            }
    }
}

/// Racine du thème : fond, texte blanc, panneaux ; sans pack de thème, l'habillage natif reste tel quel.
struct ThemeRoot<Content: View>: View {
    let section: AppSection
    @ViewBuilder var content: Content
    /// Pas observé ici (seuls les fonds l'observent) : sinon chaque fond arrivé refaisait toute la page.
    private var bg: ThemeBackgrounds { .shared }
    var body: some View {
        let on = ThemePack.shared.hasBackgrounds
        GeometryReader { g in
            ZStack {
                if on { ThemeBackdrop(section: section) }
                content
                    .groupBoxStyle(ThemePanelStyle())
                    .buttonBorderShape(.capsule)
                    .scrollContentBackground(.hidden)
                    .alternatingRowBackgrounds(.disabled)
                    .environment(\.themeGlassTint, ThemePack.shared.style(section).glassTint)
            }
            .frame(width: g.size.width, height: g.size.height)
            .coordinateSpace(name: "themeWindow")
            .onAppear { update(g.size) }
            .onChange(of: g.size) { _, n in update(n) }
            .onChange(of: section) { _, _ in update(g.size) }
        }
        .ignoresSafeArea()
        .preferredColorScheme(on ? .dark : nil)
        .accessibilityRoot()
    }
    private func update(_ s: CGSize) {
        if bg.size != s { bg.size = s }
        bg.show(section, size: s, scale: bg.scale)
    }
}
