import SwiftUI
import AppKit
import Darwin

/// État de Stockage ▸ Arborescence et Données système : un disque à la fois, analysé en arrière-plan, gardé en cache sur disque.
@MainActor
final class StorageModel: ObservableObject {
    static let shared = StorageModel()

    @Published var scopeURL = URL(fileURLWithPath: "/")
    @Published var root: SNode?
    /// Périmètre « Données système » : nœud virtuel dont les enfants sont les zones de SPEC.md trouvées dans l'arbre.
    @Published var systemRoot: SNode?
    @Published var info: StorageScan.Cached?
    @Published var scanning = false
    @Published var progress = StorageScan.Progress(entries: 0, bytes: 0, current: "")
    @Published var scanResult: (unreadable: Int, skipped: [String])?
    @Published var stats: StorageStats?
    @Published var systemStats: StorageStats?
    @Published var loaded = false
    @Published var focus: SNode?
    @Published var systemFocus: SNode?
    private var control: StorageScan.Control?
    private(set) var context = ClassContext()
    private(set) var rules: [String: ClassRule] = [:]

    var isInternal: Bool { scopeURL.path == "/" }
    /// Lecture du cache en cours : changer de sous-section (Arborescence ↔ Données système) pendant ce temps n'en relance pas une deuxième.
    private(set) var loadingNow = false

    /// Charge le cache du disque choisi (rien n'est analysé tant que l'utilisateur ne le demande pas).
    func load(_ url: URL) {
        guard !scanning, Router.shared.live else { return }
        scopeURL = url; loaded = false; loadingNow = true
        root = nil; systemRoot = nil; stats = nil; systemStats = nil; focus = nil; systemFocus = nil; info = nil
        Task.detached(priority: .utility) {
            let cached = DemoPublic.on ? (url.path == "/" ? { let c = DemoPublic.cached(); return (root: c.root.node(), info: c) }() : nil) : StorageScan.load(url)
            guard let cached else { await MainActor.run { StorageModel.shared.loaded = true; StorageModel.shared.loadingNow = false }; return }
            var ctx0 = ClassContext.live()
            if DemoPublic.on { ctx0.home = DemoPublic.home; ctx0.apps = [] }
            let ctx = ctx0
            let (s, ss, sysRoot) = Self.analyse(cached.root, internal: url.path == "/", ctx: ctx, volume: url)
            let lays = Self.layouts(cached.root, sysRoot, ctx: ctx)
            // Fenêtre fermée entre-temps : rien n'est gardé.
            await MainActor.run {
                // Posé quand Stockage est à l'écran (une page cachée ne refait rien) ; la lecture compte comme en cours jusque-là.
                Settle.shared.whenShown(.storage) {
                    let m = StorageModel.shared
                    m.loadingNow = false
                    if Router.shared.live, m.scopeURL == url, !m.scanning { m.show(root: cached.root, info: cached.info, ctx: ctx, stats: s, system: ss, sysRoot: sysRoot, layouts: lays) }
                }
            }
        }
    }

    /// Fermeture de la fenêtre : libère l'arbre et ses classements (relus depuis le cache à la prochaine ouverture). Pas pendant une analyse.
    func release() {
        guard !scanning else { return }
        root = nil; systemRoot = nil; stats = nil; systemStats = nil; focus = nil; systemFocus = nil; info = nil
        baseLayouts = []; zoomLayouts = []; loaded = false; loadingNow = false
        context = ClassContext(); rules = [:]
        // L'arbre libéré laisse des pages que malloc garde : on les rend au système une fois les vues défaites.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { malloc_zone_pressure_relief(nil, 0) }
    }

    func scan() {
        guard !scanning else { return }
        let url = scopeURL
        scanning = true; progress = StorageScan.Progress(entries: 0, bytes: 0, current: ""); scanResult = nil
        let c = StorageScan.Control()
        control = c
        Task.detached(priority: .utility) {
            let r = StorageScan.scan(url, control: c) { p in Task { @MainActor in StorageModel.shared.progress = p } }
            if !r.volumeLost { StorageScan.save(r, root: url) }
            let cached = StorageScan.Cached(root: .init(r.root), date: Date(), partial: r.partial, entries: r.entries, seconds: r.seconds, version: StorageScan.rulesVersion)
            let ctx = ClassContext.live()
            let (s, ss, sysRoot) = Self.analyse(r.root, internal: url.path == "/", ctx: ctx, volume: url, volumeLost: r.volumeLost)
            let lays = Self.layouts(r.root, sysRoot, ctx: ctx)
            await MainActor.run {
                let m = StorageModel.shared
                // Fenêtre fermée pendant l'analyse : le cache sur disque suffit, l'arbre n'est pas gardé en mémoire.
                if Router.shared.live {
                    m.show(root: r.root, info: cached, ctx: ctx, stats: s, system: ss, sysRoot: sysRoot, layouts: lays)
                    m.scanResult = (r.unreadable, r.skipped)
                }
                m.scanning = false; m.control = nil
                if !Router.shared.live { m.release() }
                ActivityStore.shared.markRun("Space Lens")
            }
        }
    }

    func cancel() { control?.cancel() }

    private nonisolated static func analyse(_ root: SNode, internal isInternal: Bool, ctx: ClassContext, volume: URL, volumeLost: Bool = false) -> (StorageStats, StorageStats?, SNode?) {
        if !volumeLost { StorageAnalysis.addUnanalysed(to: root, volume: volume) }
        let all = StorageAnalysis.compute(roots: [root], zones: isInternal ? StorageAnalysis.diskZones(home: ctx.home) : [], context: ctx, unknownMin: 100_000_000)
        guard isInternal else { return (all, nil, nil) }
        let zones = StorageAnalysis.systemDataZones(home: ctx.home)
        let nodes = StorageAnalysis.nodes(for: zones, in: root)
        let virtual = SNode(name: "Données système", size: nodes.reduce(0) { $0 + $1.size }, isDir: true)
        virtual.children = nodes.sorted { $0.size > $1.size }
        virtual.structural = true
        let sys = StorageAnalysis.compute(roots: nodes, zones: zones, context: ctx, unknownMin: 100_000_000)
        return (all, sys, virtual)
    }

    private func show(root: SNode, info: StorageScan.Cached, ctx: ClassContext, stats: StorageStats, system: StorageStats?, sysRoot: SNode?, layouts: [SunburstLayout]) {
        context = ctx
        rules = Dictionary(Classifier.rules(home: ctx.home).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        self.root = root; self.info = info; self.stats = stats; self.systemStats = system; self.systemRoot = sysRoot
        baseLayouts = layouts; zoomLayouts = []; focus = root; systemFocus = sysRoot; loaded = true
    }

    /// Dispositions des deux vues de départ (Arborescence, Données système), calculées en arrière-plan avec l'arbre, classement compris :
    /// le premier affichage et chaque retour dans la section n'ont plus rien à calculer.
    private nonisolated static func layouts(_ root: SNode, _ sysRoot: SNode?, ctx: ClassContext) -> [SunburstLayout] {
        let rules = Dictionary(Classifier.rules(home: ctx.home).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        func cat(_ n: SNode) -> StorageCategory? {
            if n.structural { return nil }
            if let c = n.cls { return c.category }
            let c = Classifier.classify(n.path, context: ctx, rules: rules)
            n.cls = c
            return c.category
        }
        return [root, sysRoot].compactMap { $0 }.map { SunburstLayout(focus: $0, category: cat) }
    }

    /// Dispositions gardées tant que la fenêtre est ouverte : les deux vues de départ et les derniers zooms (recalculées seulement
    /// pour un dossier jamais affiché).
    private var baseLayouts: [SunburstLayout] = []
    private var zoomLayouts: [SunburstLayout] = []

    func layout(for focus: SNode) -> SunburstLayout {
        if let l = (baseLayouts + zoomLayouts).first(where: { $0.focus === focus }) { return l }
        let l = SunburstLayout(focus: focus) { n in n.structural ? nil : classification(n).category }
        // Images gardées : les deux vues de départ et le dernier zoom seulement (quelques Mo chacune).
        zoomLayouts.forEach { $0.image = nil }
        zoomLayouts = Array((zoomLayouts + [l]).suffix(4))
        return l
    }

    func classification(_ n: SNode) -> Classification {
        if let c = n.cls { return c }
        let c = Classifier.classify(n.path, context: context, rules: rules)
        n.cls = c
        return c
    }

    /// Protection qui prime sur la catégorie (lecture seule, projet, bloqué).
    func protection(_ n: SNode) -> String? {
        let u = URL(fileURLWithPath: n.path)
        if Ignore.blocked(u) { return "Bloqué" }
        if Ignore.readOnly(u) { return "Lecture seule (protégé)" }
        return nil
    }
}

// MARK: - Anneaux (sunburst)

extension StorageCategory {
    /// Couleurs vives par catégorie (même correspondance qu'avant : vert, orange, violet, bleu, gris, jaune).
    var color: Color {
        switch self {
        case .regenerable: Palette.grass
        case .appLeftover: Palette.ember
        case .movable: Palette.violet
        case .keep: Palette.sky
        case .system: Palette.silver
        case .unknown: Palette.sun
        }
    }

    /// Les mêmes couleurs en composantes sRGB, pour le dessin hors du fil principal (`SunburstImage`).
    var rgb: SIMD3<Double> {
        switch self {
        case .regenerable: SIMD3(0x7E, 0xD3, 0x21) / 255
        case .appLeftover: SIMD3(0xFF, 0x7A, 0x1A) / 255
        case .movable: SIMD3(0x8A, 0x5C, 0xFF) / 255
        case .keep: SIMD3(0x2E, 0x8B, 0xFF) / 255
        case .system: SIMD3(0xAE, 0xB9, 0xC8) / 255
        case .unknown: SIMD3(0xFF, 0xD4, 0x3B) / 255
        }
    }
}

/// Disposition calculée une fois par zoom : angles en radians depuis le haut (12 h), dans le sens horaire.
final class SunburstLayout: @unchecked Sendable {
    /// `category` nil : dossier de regroupement (dessiné en neutre, la couleur se lit sur ses sous-dossiers).
    /// `others` : regroupement des enfants de moins de 1° de `node` (un seul par parent, jamais détaillé).
    struct Arc { let node: SNode; let depth: Int; let a0: Double; let a1: Double; let category: StorageCategory?; var others = false }
    let id = UUID()
    let focus: SNode
    private(set) var arcs: [Arc] = []
    /// Dernière image des anneaux (clé = taille et échelle), posée sur le fil principal par `SunburstRings`.
    @MainActor var image: (key: String, image: CGImage)?
    static let rings = 6
    /// Un arc plus étroit n'est pas dessiné (invisible, et il alourdirait le dessin).
    static let minAngle = 0.006
    /// Les enfants plus étroits sont regroupés en un seul segment « autres » par parent : plus de traits fins.
    static let groupAngle = Double.pi / 180

    init(focus: SNode, category: (SNode) -> StorageCategory?) {
        self.focus = focus
        func place(_ n: SNode, _ a0: Double, _ a1: Double, _ depth: Int) {
            guard depth <= Self.rings, n.size > 0 else { return }
            var a = a0, small = 0.0
            for k in n.children {
                let span = (a1 - a0) * Double(k.size) / Double(n.size)
                guard span >= Self.groupAngle else { small += span; continue }
                arcs.append(Arc(node: k, depth: depth, a0: a, a1: a + span, category: category(k)))
                place(k, a, a + span, depth + 1)
                a += span
            }
            if small >= Self.minAngle { arcs.append(Arc(node: n, depth: depth, a0: a, a1: a + small, category: nil, others: true)) }
        }
        place(focus, 0, 2 * .pi, 1)
    }

    /// Radii: centre libre `hole`, puis `rings` anneaux d'égale épaisseur jusqu'à `radius`.
    static func radii(_ depth: Int, _ radius: Double) -> (Double, Double) {
        let hole = radius * 0.2, w = (radius - hole) / Double(rings)
        return (hole + w * Double(depth - 1), hole + w * Double(depth))
    }

    func arc(at p: CGPoint, in size: CGSize) -> Arc? {
        let radius = min(size.width, size.height) / 2 - 6
        let dx = p.x - size.width / 2, dy = p.y - size.height / 2
        let r = hypot(dx, dy)
        var a = atan2(dy, dx) + .pi / 2
        if a < 0 { a += 2 * .pi }
        return arcs.first { x in
            let (r0, r1) = Self.radii(x.depth, radius)
            return r >= r0 && r < r1 && a >= x.a0 && a < x.a1
        }
    }
}

/// Géométrie et dessin des anneaux (DESIGN.md §13) : segments séparés de 2 pt, coins arrondis, dégradé radial plus clair vers le centre,
/// reflet discret sur le bord extérieur. Tous les anneaux d'un zoom sont dessinés **une fois, hors du fil principal**, dans une image à
/// la taille en pixels de la vue (`render`) ; le fil principal ne fait qu'afficher cette image (mesuré rc1 : 84 ms au premier affichage
/// quand chaque anneau était un `Canvas` dessiné sur le fil principal).
enum SunburstImage {
    private static let nightBlue = SIMD3<Double>(0x06, 0x20, 0x4A) / 255
    private static let silver = SIMD3<Double>(0xAE, 0xB9, 0xC8) / 255

    /// Couleur pleine d'un segment (côté extérieur) en sRGB + opacité.
    static func rgba(_ a: SunburstLayout.Arc) -> SIMD4<Double> {
        if a.others { return SIMD4(silver, 0.45) }
        guard let cat = a.category else { return SIMD4(1, 1, 1, 0.16) }
        let k = 0.05 * Double(a.depth - 1)
        return SIMD4(cat.rgb * (1 - k) + nightBlue * k, 1)
    }

    static func color(_ a: SunburstLayout.Arc) -> Color {
        let c = rgba(a)
        return Color(.sRGB, red: c.x, green: c.y, blue: c.z, opacity: c.w)
    }

    /// Dégradé radial (SwiftUI, segment survolé) : plus clair côté centre, couleur pleine côté extérieur.
    static func shading(_ a: SunburstLayout.Arc, _ c: CGPoint, _ radius: Double) -> GraphicsContext.Shading {
        let (r0, r1) = SunburstLayout.radii(a.depth, radius)
        let col = color(a)
        return .radialGradient(Gradient(colors: [col.mix(with: .white, by: 0.3), col]), center: c, startRadius: r0, endRadius: r1)
    }

    /// Image de tous les anneaux de `layout` pour une vue de `size` points à l'échelle `scale` (appelable hors du fil principal).
    static func render(_ layout: SunburstLayout, size: CGSize, scale: CGFloat) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Repère de SwiftUI (origine en haut à gauche, y vers le bas), en points.
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: scale, y: -scale)
        let radius = min(size.width, size.height) / 2 - 6
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        func cg(_ v: SIMD4<Double>) -> CGColor { CGColor(colorSpace: space, components: [v.x, v.y, v.z, v.w])! }
        for a in layout.arcs {
            guard let path = path(a, c, radius) else { continue }
            let (r0, r1) = SunburstLayout.radii(a.depth, radius)
            let outer = rgba(a)
            let inner = SIMD4(SIMD3(outer.x, outer.y, outer.z) * 0.7 + 0.3, outer.w * 0.7 + 0.3)
            ctx.saveGState()
            ctx.addPath(path.cgPath); ctx.clip()
            if let g = CGGradient(colorsSpace: space, colors: [cg(inner), cg(outer)] as CFArray, locations: [0, 1]) {
                ctx.drawRadialGradient(g, startCenter: c, startRadius: r0, endCenter: c, endRadius: r1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()
            if let shine = shine(a, c, radius) {
                ctx.addPath(shine.cgPath)
                ctx.setStrokeColor(cg(SIMD4(1, 1, 1, 0.28))); ctx.setLineWidth(1); ctx.setLineCap(.round)
                ctx.strokePath()
            }
        }
        return ctx.makeImage()
    }

    private static func pt(_ c: CGPoint, _ r: Double, _ t: Double) -> CGPoint { CGPoint(x: c.x + r * sin(t), y: c.y - r * cos(t)) }
    private static func ang(_ t: Double) -> Angle { .radians(t - .pi / 2) }

    /// Écart entre segments (2 pt, moins pour les segments très étroits) et rayon des coins (4 pt au plus).
    private static func geometry(_ a: SunburstLayout.Arc, _ radius: Double) -> (r0: Double, r1: Double, gap: Double, rc: Double)? {
        let (R0, R1) = SunburstLayout.radii(a.depth, radius)
        let r0 = R0 + 1, r1 = R1 - 1
        let inner = (a.a1 - a.a0) * r0
        let gap = min(2, inner * 0.35)
        let rc = max(0, min(4, (r1 - r0) / 2.5, (inner - gap) / 2.5))
        guard r1 > r0, inner - gap > 0.3 else { return nil }
        return (r0, r1, gap, rc)
    }

    static func path(_ a: SunburstLayout.Arc, _ c: CGPoint, _ radius: Double) -> Path? {
        guard let g = geometry(a, radius) else { return nil }
        let (r0, r1, gap, rc) = g
        let s1 = a.a0 + gap / 2 / r1, e1 = a.a1 - gap / 2 / r1
        let s0 = a.a0 + gap / 2 / r0, e0 = a.a1 - gap / 2 / r0
        var p = Path()
        p.move(to: pt(c, (r0 + r1) / 2, (s0 + s1) / 2))
        p.addArc(tangent1End: pt(c, r1, s1), tangent2End: pt(c, r1, s1 + 2 * rc / r1), radius: rc)
        p.addArc(center: c, radius: r1, startAngle: ang(s1 + rc / r1), endAngle: ang(max(s1 + rc / r1, e1 - rc / r1)), clockwise: false)
        p.addArc(tangent1End: pt(c, r1, e1), tangent2End: pt(c, r0, e0), radius: rc)
        p.addArc(tangent1End: pt(c, r0, e0), tangent2End: pt(c, r0, e0 - 2 * rc / r0), radius: rc)
        p.addArc(center: c, radius: r0, startAngle: ang(e0 - rc / r0), endAngle: ang(min(e0 - rc / r0, s0 + rc / r0)), clockwise: true)
        p.addArc(tangent1End: pt(c, r0, s0), tangent2End: pt(c, r1, s1), radius: rc)
        p.closeSubpath()
        return p
    }

    /// Reflet : fin arc blanc juste sous le bord extérieur des segments assez larges.
    static func shine(_ a: SunburstLayout.Arc, _ c: CGPoint, _ radius: Double) -> Path? {
        guard let g = geometry(a, radius), (a.a1 - a.a0) * g.r1 > 14, !a.others, a.category != nil else { return nil }
        let r = g.r1 - 2.5, inset = (g.gap / 2 + g.rc + 3) / r
        guard a.a1 - a.a0 > 2 * inset else { return nil }
        var p = Path()
        p.addArc(center: c, radius: r, startAngle: ang(a.a0 + inset), endAngle: ang(a.a1 - inset), clockwise: false)
        return p
    }
}

/// Les anneaux d'un zoom : image dessinée hors du fil principal (gardée par la disposition pour sa taille), qui pousse depuis le centre à
/// son arrivée (Motion.content, tous les anneaux ensemble, sans rebond ni cascade) : en zoom avant elle grandit depuis le centre, en zoom
/// arrière elle se resserre depuis l'extérieur. Image fixe ensuite ; un redimensionnement de la fenêtre la redessine en arrière-plan.
struct SunburstRings: View {
    let layout: SunburstLayout
    let size: CGSize
    let zoomOut: Bool
    @Environment(\.displayScale) private var scale
    @Local private var image: CGImage?
    @Local private var shown = false

    var body: some View {
        let key = "\(Int(size.width))x\(Int(size.height))@\(scale)"
        ZStack {
            if let image { Image(decorative: image, scale: scale).resizable().frame(width: size.width, height: size.height) }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(shown ? 1 : (zoomOut ? 1.25 : 0.35))
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(false)
        .task(id: key) {
            if let c = layout.image, c.key == key { image = c.image }
            else {
                // Redimensionnement en cours : on attend qu'il se calme avant de redessiner (l'ancienne image reste affichée, étirée).
                if image != nil { try? await Task.sleep(nanoseconds: 120_000_000); if Task.isCancelled { return } }
                let (l, sz, sc) = (layout, size, scale)
                guard let r = await Task.detached(priority: .userInitiated, operation: { SunburstImage.render(l, size: sz, scale: sc) }).value,
                      !Task.isCancelled else { return }
                layout.image = (key, r)
                image = r
            }
            if !shown { withAnimation(Motion.content) { shown = true } }
        }
    }
}

/// Segment survolé : soulevé doucement vers l'extérieur, plus clair, avec une ombre (Motion.detail).
struct SunburstLift: View {
    let arc: SunburstLayout.Arc
    @Local private var lifted = false
    var body: some View {
        let mid = (arc.a0 + arc.a1) / 2
        Canvas { ctx, size in
            let radius = min(size.width, size.height) / 2 - 6
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            guard let p = SunburstImage.path(arc, c, radius) else { return }
            ctx.addFilter(.shadow(color: Palette.nightBlue.opacity(0.45), radius: 6, y: 2))
            ctx.fill(p, with: SunburstImage.shading(arc, c, radius))
            ctx.fill(p, with: .color(.white.opacity(0.14)))
            ctx.stroke(p, with: .color(.white.opacity(0.7)), lineWidth: 1)
        }
        .offset(x: lifted ? 4 * sin(mid) : 0, y: lifted ? -4 * cos(mid) : 0)
        .scaleEffect(lifted ? 1.01 : 1)
        .onAppear { withAnimation(Motion.detail) { lifted = true } }
        .allowsHitTesting(false)
    }
}

struct StorageView: View {
    enum Mode { case tree, systemData }
    let mode: Mode
    @ObservedObject var m = StorageModel.shared
    let monitor = SystemMonitor.shared
    @Local private var hover: SunburstLayout.Arc?
    @Local private var selected: SNode?
    /// Dernier zoom vers un dossier parent : les anneaux se resserrent depuis l'extérieur au lieu de pousser depuis le centre.
    @Local private var zoomOut = false
    /// Liste « Restés Inconnu » dépliée en entier (8 lignes sinon).
    @Local private var allUnknown = false

    var root: SNode? { mode == .tree ? m.root : m.systemRoot }
    var focus: SNode? { mode == .tree ? m.focus : m.systemFocus }
    var stats: StorageStats? { mode == .tree ? m.stats : m.systemStats }

    func setFocus(_ n: SNode) {
        guard n !== focus else { return }
        zoomOut = sequence(first: focus?.parent, next: { $0?.parent }).contains { $0 === n }
        if mode == .tree { m.focus = n } else { m.systemFocus = n }
        selected = nil; hover = nil
    }

    var body: some View {
        Group {
            if m.scanning { scanning }
            else if mode == .systemData && !m.isInternal { message("Les données système concernent le disque interne.", "Choisissez « Disque interne » dans le menu Disque.") }
            else if let root, let focus { Deferred { explorer(root, focus) } }
            else if !m.loaded { LiquidRing(size: 28).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { empty }
        }
        .pageActions {
            Menu {
                Button("Disque interne") { m.load(URL(fileURLWithPath: "/")) }
                ForEach(monitor.devices.filter { $0.kind == "drive" && $0.url != nil }) { d in Button(d.name) { m.load(d.url!) } }
            } label: { Label("Disque", systemImage: "internaldrive") }.disabled(m.scanning)
            Button { m.scan() } label: { Label("Analyser à nouveau", systemImage: "arrow.clockwise") }.disabled(m.scanning).help("Analyser à nouveau ce disque")
        }
        .onShow { if m.root == nil && !m.scanning && !m.loaded && !m.loadingNow { m.load(m.scopeURL) } }
    }

    // MARK: États

    var empty: some View {
        EmptyState("Disque \(m.isInternal ? "interne" : m.scopeURL.lastPathComponent) : pas encore analysé",
                   detail: "L'analyse tourne en arrière-plan, lit seulement les tailles et se garde sur le disque.", symbol: "chart.pie") {
            Button("Analyser") { m.scan() }.buttonStyle(.borderedProminent)
        }
    }

    func message(_ title: String, _ detail: String) -> some View { EmptyState(title, detail: detail, symbol: "internaldrive") }

    var scanning: some View {
        VStack(spacing: 10) {
            LiquidRing(size: 72)
            Text("Analyse en cours : \(m.progress.entries) éléments · \(Fmt.bytes(m.progress.bytes))").monospacedDigit()
            Text(m.progress.current.replacingOccurrences(of: FS.home.path, with: "~")).font(Typo.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
            Button("Annuler", role: .cancel) { m.cancel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Explorateur

    func explorer(_ root: SNode, _ focus: SNode) -> some View {
        VStack(spacing: 0) {
            breadcrumb(root, focus)
            Divider()
            HStack(spacing: 0) {
                GeometryReader { g in
                    let lay = m.layout(for: focus)
                    let hole = (min(g.size.width, g.size.height) / 2 - 6) * 0.2
                    ZStack {
                        SunburstRings(layout: lay, size: g.size, zoomOut: zoomOut).id(lay.id)
                        if let h = hover { SunburstLift(arc: h).id("\(ObjectIdentifier(h.node).hashValue)-\(h.depth)-\(h.others)") }
                        // Centre : bulle de verre native avec le nom et la taille du dossier affiché.
                        VStack(spacing: 2) {
                            Text(displayName(focus, root)).font(Typo.headline).lineLimit(1).minimumScaleFactor(0.7)
                            Text(Fmt.bytes(focus.size)).font(Typo.detail).monospacedDigit().foregroundStyle(Palette.inkSecondary)
                        }
                        .padding(.horizontal, 8)
                        .frame(width: max(1, 2 * hole - 6), height: max(1, 2 * hole - 6))
                        .glassSurface(.regular.tint(Palette.sky.opacity(0.2)), in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                        .shadow(color: Palette.nightBlue.opacity(0.3), radius: 6, y: 2)
                        .allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): let a = lay.arc(at: p, in: g.size); if a?.node !== hover?.node || a?.depth != hover?.depth { hover = a }
                        case .ended: hover = nil
                        }
                    }
                    .onTapGesture { p in
                        if let a = lay.arc(at: p, in: g.size) {
                            if !a.others && a.node.isDir && !a.node.children.isEmpty { setFocus(a.node) } else { selected = a.node }
                        } else if hypot(p.x - g.size.width / 2, p.y - g.size.height / 2) < min(g.size.width, g.size.height) / 2 * 0.2 {
                            let chain = focus.chain(upTo: root)
                            if chain.count > 1 { setFocus(chain[chain.count - 2]) }
                        }
                    }
                }
                .padding(Space.gap)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                side(root, focus).frame(width: 360).themePanel().padding([.top, .trailing, .bottom], 12)
            }
            if mode == .systemData, let s = stats { Divider(); zoneTable(s).padding(.horizontal, Space.page).padding(.vertical, 10) }
            footer
        }
    }

    func displayName(_ n: SNode, _ root: SNode) -> String { n === root && mode == .tree ? FS.displayName(URL(fileURLWithPath: n.name)).replacingOccurrences(of: "/", with: "Disque") : n.name }

    func breadcrumb(_ root: SNode, _ focus: SNode) -> some View {
        HStack(spacing: 4) {
            let chain = focus.chain(upTo: root)
            ForEach(Array(chain.enumerated()), id: \.offset) { i, n in
                Button(displayName(n, root)) { setFocus(n) }.buttonStyle(.borderless)
                    .foregroundStyle(n === focus ? .primary : .secondary)
                if i < chain.count - 1 { Image(systemName: "chevron.right").font(Typo.caption).foregroundStyle(.tertiary) }
            }
            Spacer()
            Text(Fmt.bytes(focus.size)).font(Typo.headline).monospacedDigit()
        }
        .padding(.horizontal, Space.page).padding(.vertical, 10)
    }

    // MARK: Panneau latéral

    func side(_ root: SNode, _ focus: SNode) -> some View {
        let node = hover?.node ?? selected ?? focus
        // Défilement estompé en haut et en bas, marge basse égale au rayon du panneau : la dernière ligne n'est jamais coupée par le coin arrondi.
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                detail(node, within: root.size)
                if let s = stats { legend(s) }
                if mode == .tree, m.isInternal, let s = m.stats, !s.unknown.isEmpty { unknownList(s) }
            }
            .padding(Space.panel).padding(.bottom, Radius.panel - Space.panel + 8)
        }
        .scrollEdgeFade()
    }

    func detail(_ n: SNode, within total: Int64) -> some View {
        let c = m.classification(n)
        return GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill(n.structural ? Color.primary.opacity(0.2) : c.category.color).frame(width: 10, height: 10)
                    Text(n.structural ? "Dossier de regroupement" : c.category.label).font(Typo.headline)
                    Spacer()
                    Text(Fmt.bytes(n.size)).monospacedDigit().font(Typo.headline)
                }
                Text(n.path.replacingOccurrences(of: FS.home.path, with: "~")).font(Typo.detail).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Text(n.structural ? "Aucune règle pour ce dossier lui-même : la catégorie se lit sur ses sous-dossiers. Ce qui n'y est pas détaillé reste « Inconnu »." : c.reason)
                    .font(Typo.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let p = m.protection(n) {
                    Label(p + " · aucune action", systemImage: "lock.fill").font(Typo.detail).foregroundStyle(.secondary)
                } else {
                    Text("Action : \(c.category.action)").font(Typo.detail).foregroundStyle(.secondary)
                }
                if total > 0 { Text(Fmt.percent(Double(n.size) * 100 / Double(total), digits: 1) + " de l'ensemble").font(Typo.caption).foregroundStyle(.tertiary) }
                if n.path.hasPrefix("/") && FS.exists(URL(fileURLWithPath: n.path)) {
                    Button("Afficher dans le Finder") { FS.reveal(URL(fileURLWithPath: n.path)) }.controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func legend(_ s: StorageStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Par catégorie").font(Typo.headline)
            ForEach(StorageCategory.allCases, id: \.self) { c in
                HStack {
                    Circle().fill(c.color).frame(width: 10, height: 10)
                    Text(c.label)
                    Spacer()
                    Text(Fmt.bytes(s.byCategory[c] ?? 0)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack { Text("Total analysé"); Spacer(); Text(Fmt.bytes(s.total)).monospacedDigit() }.foregroundStyle(.secondary)
        }
    }

    func zoneTable(_ s: StorageStats) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 3) {
            GridRow {
                Text("Par zone et par catégorie").font(Typo.headline).gridColumnAlignment(.leading)
                ForEach(StorageCategory.allCases, id: \.self) { c in
                    HStack(spacing: 4) { Circle().fill(c.color).frame(width: 8, height: 8); Text(c.label) }.font(Typo.caption)
                }
                Text("Total").font(.caption.weight(.semibold))
            }
            ForEach(Array(s.zoneNames.enumerated()), id: \.offset) { i, name in
                let row = s.byZone[i]
                let total = row.values.reduce(0, +)
                if total > 0 {
                    GridRow {
                        Text(name).gridColumnAlignment(.leading)
                        ForEach(StorageCategory.allCases, id: \.self) { c in Text(short(row[c] ?? 0)).monospacedDigit().foregroundStyle((row[c] ?? 0) == 0 ? .tertiary : .primary) }
                        Text(short(total)).fontWeight(.semibold).monospacedDigit()
                    }
                }
            }
            GridRow {
                Text("Ensemble").fontWeight(.semibold).gridColumnAlignment(.leading)
                ForEach(StorageCategory.allCases, id: \.self) { c in Text(short(s.byCategory[c] ?? 0)).monospacedDigit().fontWeight(.semibold) }
                Text(short(s.total)).monospacedDigit().fontWeight(.semibold)
            }
        }
        .font(Typo.detail)
    }

    func short(_ b: Int64) -> String { b == 0 ? "–" : Fmt.bytes(b).replacingOccurrences(of: " ", with: "\u{202F}") }

    func unknownList(_ s: StorageStats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Restés « Inconnu » (> 100 Mo)").font(Typo.headline)
            ForEach(Array(s.unknown.prefix(allUnknown ? s.unknown.count : 8).enumerated()), id: \.offset) { _, u in
                HStack {
                    Text(u.path.replacingOccurrences(of: FS.home.path, with: "~")).font(Typo.detail).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Fmt.bytes(u.size)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if s.unknown.count > 8 {
                Button(allUnknown ? "Afficher moins" : "Tout afficher (\(s.unknown.count))") { withAnimation(Motion.detail) { allUnknown.toggle() } }
                    .buttonStyle(.borderless).font(Typo.detail)
            }
        }
    }

    var footer: some View {
        HStack {
            if let i = m.info {
                Text("Analysé \(Fmt.ago(i.date)) · \(i.entries) éléments · \(Fmt.duration(i.seconds))\(i.partial ? " · analyse partielle (budget de temps atteint ou annulée)" : "")")
            }
            if let r = m.scanResult, r.unreadable > 0 { Text("· \(r.unreadable) non lus (accès refusé)") }
            if let r = m.scanResult, !r.skipped.isEmpty { Text("· \(r.skipped.count) ignorés (bloqués, cloud non téléchargé ou montages)") }
            Spacer()
        }
        .font(Typo.caption).foregroundStyle(.secondary)
        .padding(.horizontal, Space.page).padding(.vertical, 6)
    }
}

// MARK: - Déplacer vers le disque de données

struct RelocateView: View {
    @ObservedObject var model = RelocateModel.shared
    @Local private var refused: String?
    @Local private var chosen = Config.current?.dataDisk

    var body: some View {
        let target = Config.relocateTarget
        Form {
            Section {
                LabeledContent {
                    Button(chosen == nil ? "Choisir…" : "Changer…") {
                        refused = DataDisk.choose()
                        chosen = Config.current?.dataDisk
                        model.refresh()
                    }
                } label: {
                    Text("Disque de données")
                    Text(target.map { "« \($0.name) » branché" } ?? (chosen.map { "« \($0.volume.name) » non branché" } ?? "Aucun disque choisi"))
                    if let refused { Text(refused).foregroundStyle(.red) }
                }
                if model.loading { HStack { LiquidRing(size: 18); Text("Mesure de la place prise sur le disque interne…").foregroundStyle(.secondary) } }
            } footer: {
                Text("zerOS ne déplace rien lui-même : il mesure, explique la marche à suivre et ouvre l'app concernée. Chaque app déplace ses données avec son propre réglage.")
            }
            ForEach(model.items) { item in
                Section {
                    DisclosureGroup {
                        ForEach(Array(item.entry.steps.enumerated()), id: \.offset) { i, s in
                            Text("\(i + 1). \(s)").fixedSize(horizontal: false, vertical: true)
                        }
                        if let u = item.entry.unverified { Label(u, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                        if let n = item.entry.note { Text(n).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        ForEach(item.folders, id: \.path) { f in
                            LabeledContent(f.path.replacingOccurrences(of: FS.home.path, with: "~")) {
                                HStack {
                                    Text(Fmt.bytes(f.size)).monospacedDigit().foregroundStyle(.secondary)
                                    Button("Afficher") { FS.reveal(URL(fileURLWithPath: f.path)) }.controlSize(.small)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.entry.name)
                                Text(status(item)).font(Typo.detail).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.size > 0 ? Fmt.bytes(item.size) : "–").monospacedDigit().font(Typo.headline)
                            ForEach(item.installed.prefix(2), id: \.path) { a in
                                Button("Ouvrir \(a.name)") { NSWorkspace.shared.open(URL(fileURLWithPath: a.path)) }.controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .pageActions {
            Button { model.refresh(force: true) } label: { Label("Mesurer à nouveau", systemImage: "arrow.clockwise") }.disabled(model.loading)
        }
        .onAppear { model.refresh() }
    }

    func status(_ i: RelocateItem) -> String {
        let app = i.installed.isEmpty ? "app non installée" : "\(i.installed[0].name) installée"
        return i.size > 0 ? "\(app) · \(Fmt.bytes(i.size)) sur le disque interne" : "\(app) · rien sur le disque interne"
    }
}
