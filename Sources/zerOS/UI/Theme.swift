import SwiftUI
import AppKit

extension Module {
    var title: String {
        switch self {
        case .smartCare: "Aujourd'hui"
        case .cleanup: "Nettoyage"
        case .performance: "Performance"
        case .applications: "Applications"
        case .clutter: "Mon désordre"
        case .spaceLens: "Arborescence"
        case .systemData: "Données système"
        case .relocate: "Déplacer vers le disque de données"
        case .cloud: "Nettoyage du cloud"
        case .activity: "Journal"
        }
    }

    var symbol: String {
        switch self {
        case .smartCare: "sun.max"
        case .cleanup: "bubbles.and.sparkles"
        case .performance: "gauge.with.dots.needle.67percent"
        case .applications: "square.grid.2x2.fill"
        case .clutter: "doc.on.doc.fill"
        case .spaceLens: "circle.hexagongrid.fill"
        case .systemData: "gearshape.2.fill"
        case .relocate: "arrow.right.circle.fill"
        case .cloud: "icloud.fill"
        case .activity: "chart.bar.xaxis"
        }
    }

    /// System colour of the module (sidebar-style icons, figures). Semantic, follows light and dark mode.
    var tint: Color {
        switch self {
        case .smartCare: .pink
        case .cleanup: .green
        case .performance: .orange
        case .applications: .blue
        case .clutter: .teal
        case .spaceLens: .purple
        case .systemData: .gray
        case .relocate: .indigo
        case .cloud: .cyan
        case .activity: .indigo
        }
    }

    var tagline: String {
        switch self {
        case .smartCare: "L'état du Mac et les actions utiles."
        case .cleanup: "Supprimez les fichiers inutiles du système, les pièces jointes, les corbeilles et les restes des apps d'IA."
        case .performance: "Réparations manuelles et instantanés Time Machine."
        case .applications: "Désinstallez proprement, supprimez les restes d'apps et gardez tout à jour."
        case .clutter: "Retrouvez les gros fichiers oubliés, les doublons et les photos qui se ressemblent."
        case .spaceLens: "Une carte de votre disque, colorée par catégorie, pour voir d'un coup d'œil ce qui prend de la place."
        case .systemData: "Ce que macOS compte dans « Données système », découpé et classé."
        case .relocate: "Les données d'apps qui se déplacent vers le disque de données, avec la marche à suivre."
        case .cloud: "Libérez de l'espace sur le Mac en gardant vos fichiers iCloud, Google Drive et Dropbox en ligne."
        case .activity: "Ce que zerOS a fait : nettoyages, désinstallations, alertes."
        }
    }
}

// MARK: - Reusable pieces

/// Module symbol on a rounded square of its colour, like System Settings icons.
struct ModuleIcon: View {
    let module: Module
    var size: CGFloat = 26
    var body: some View { SymbolTile(symbol: module.symbol, color: module.tint, size: size) }
}

struct SymbolTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 26
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

/// Main action of a page: system prominent button (accent colour of the Mac).
struct PrimaryButton: View {
    let title: String
    var symbol: String? = nil
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
        .buttonStyle(ThemePrimaryButtonStyle())
        .disabled(disabled)
    }
}

/// Case à cocher avec l'état mixte (`nil`) que le Toggle de SwiftUI n'a pas. Dessinée en SwiftUI (forme et taille de la case macOS) :
/// une case AppKit par ligne de liste coûtait la création d'un NSButton à chaque affichage de liste (mesuré 0.9.9, à-coups d'Apps).
/// Interrupteur dessiné en SwiftUI (aucune vue AppKit par ligne, comme `Checkbox`) : listes longues (Apps > Arrière-plan).
struct LightSwitch: View {
    let on: Bool
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule().fill(on ? AnyShapeStyle(Palette.sky) : AnyShapeStyle(Color.white.opacity(0.16)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0.35 : 0.5), lineWidth: 1))
                .overlay(alignment: on ? .trailing : .leading) { Circle().fill(.white).padding(2.5).shadow(color: .black.opacity(0.2), radius: 1, y: 0.5) }
                .frame(width: 32, height: 18)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .animation(Motion.detail, value: on)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? "activé" : "désactivé")
    }
}

struct Checkbox: View {
    let state: Bool?
    var disabled = false
    let action: () -> Void

    var body: some View {
        let on = state != false
        Button(action: action) {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(on ? AnyShapeStyle(Palette.sky) : AnyShapeStyle(Color.white.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(Color.white.opacity(on ? 0.35 : 0.55), lineWidth: 1))
                .overlay {
                    if on { Image(systemName: state == nil ? "minus" : "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white) }
                }
                .frame(width: 14, height: 14)
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .animation(Motion.detail, value: state)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(state == true ? "coché" : (state == false ? "non coché" : "en partie coché"))
    }
}

/// Floating bar at the bottom of a page: Liquid Glass, or an opaque bar when "Reduce transparency" is on.
struct FloatingBar<Content: View>: View {
    @Environment(\.opaqueSurfaces) private var reduceTransparency
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        HStack(spacing: 10) { content }
            .padding(.horizontal, Space.panel).padding(.vertical, 10)
            .background {
                if reduceTransparency { shape.fill(.background).overlay(shape.strokeBorder(.separator)) }
            }
            .glassSurface(reduceTransparency ? .identity : .regular, in: shape)
            .padding(.horizontal, Space.panel).padding(.bottom, 14)
    }
}

/// Icônes de fichiers et d'apps : lues hors du fil principal et réduites une fois à la taille affichée (une icône d'app contient des
/// images jusqu'à 1024 px, qu'il fallait sinon réduire à chaque affichage). Libérées à la fermeture de la fenêtre.
enum IconCache {
    private static let cache = NSCache<NSString, CGImage>()
    static func release() { cache.removeAllObjects() }
    private static func key(_ path: String, _ px: Int) -> NSString { "\(px):\(path)" as NSString }

    /// Déjà prête (aucun calcul) : affichée tout de suite, sans fondu.
    static func cached(_ path: String, px: Int) -> CGImage? { cache.object(forKey: key(path, px)) }

    /// Lecture et réduction en arrière-plan ; nil si le fichier n'existe pas.
    static func load(_ path: String, px: Int) async -> CGImage? {
        if let i = cached(path, px: px) { return i }
        return await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: path)
            guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            let rect = NSRect(x: 0, y: 0, width: px, height: px)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            icon.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
            guard let img = ctx.makeImage() else { return nil }
            cache.setObject(img, forKey: key(path, px))
            return img
        }.value
    }
}

/// Icône d'un fichier ou d'une app : symbole discret tant que l'icône réduite n'est pas prête, puis fondu (Motion.detail).
struct ItemIcon: View {
    let path: String?
    let symbol: String?
    var size: CGFloat = 28
    @Local private var image: CGImage?
    private var px: Int { Int(size * 2) }

    var body: some View {
        Group {
            if let img = image ?? path.flatMap({ IconCache.cached($0, px: px) }) {
                Image(decorative: img, scale: 2).resizable()
            } else {
                Image(systemName: symbol ?? "doc").font(.system(size: size * 0.5)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: path) {
            guard let path, IconCache.cached(path, px: px) == nil else { return }
            let img = await IconCache.load(path, px: px)
            withAnimation(Motion.detail) { image = img }
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var color: Color = .accentColor
    var body: some View {
        GeometryReader { g in
            let mx = max(values.max() ?? 1, 1)
            Path { p in
                for (i, v) in values.enumerated() {
                    let x = g.size.width * CGFloat(i) / CGFloat(max(1, values.count - 1))
                    let y = g.size.height * (1 - CGFloat(v / mx))
                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}

struct FDABanner: View {
    var body: some View {
        if !Perms.Access.shared.fullDisk {
            GroupBox {
                HStack(spacing: 12) {
                    Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange).font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Donnez l'accès complet au disque").fontWeight(.semibold)
                        Text("Sans lui, zerOS ne voit pas Mail, Safari, la Corbeille et d'autres dossiers protégés par macOS.").font(Typo.detail).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Ouvrir les réglages") { Perms.openFullDiskAccess() }
                }
                .padding(4)
            }
        }
    }
}

/// Popover explaining an item with Apple Intelligence.
struct InsightButton: View {
    let title: String
    let path: String?
    let context: String
    @Local private var show = false
    @Local private var text: String?
    var body: some View {
        Button { show = true } label: { Image(systemName: "sparkle.magnifyingglass") }
            .buttonStyle(.borderless)
            .help("Qu'est-ce que c'est ? (Smart Insights)")
            .popover(isPresented: $show) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Smart Insights", systemImage: "sparkles").font(Typo.headline).foregroundStyle(.tint)
                    Text(title).fontWeight(.semibold)
                    if let text { Text(text).fixedSize(horizontal: false, vertical: true) }
                    else { LiquidRing(size: 18) }
                }
                .padding(Space.panel).frame(width: 340)
                .task {
                    if text == nil { text = await SmartInsights.explain(title: title, path: path, context: context) }
                }
            }
    }
}

/// The SDK declares `State` both as a macro and a property wrapper; the macro plugin only ships with Xcode.
typealias Local = SwiftUI.State
