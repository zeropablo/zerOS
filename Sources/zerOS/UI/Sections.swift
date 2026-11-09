import SwiftUI
import AppKit

// MARK: - Sous-vues provisoires (Stockage)

/// Une section qui regroupe d'anciens modules : sélecteur en haut (capsule de verre dans le contenu), ancien écran dessous.
struct SubviewPage: View {
    let section: AppSection
    let router = Router.shared

    var body: some View {
        let current = router.sub[section] ?? section.subviews[0].0
        TabDeck(tabs: section.subviews.map { ($0.0.rawValue, $0.1) }, selection: current.rawValue, select: { id in
            if let m = Module(rawValue: id) { router.sub[section] = m }
        }) { id in
            switch Module(rawValue: id) {
            case .cleanup: CleanupView()
            case .clutter: ClutterView()
            case .spaceLens: StorageView(mode: .tree)
            case .systemData: StorageView(mode: .systemData)
            case .relocate: RelocateView()
            case .cloud: CloudView()
            default: EmptyView()
            }
        }
    }
}

// MARK: - Aujourd'hui

struct TodayView: View {
    let monitor = SystemMonitor.shared
    @ObservedObject var cleanup = AppSessions.cleanup
    @ObservedObject var relocate = RelocateModel.shared
    let nav = Nav.shared

    /// Mêmes données que l'autotest, lues dans le moniteur déjà en place (rien de plus à mesurer).
    var snapshot: TodaySnapshot {
        let reclaimable: Int64? = cleanup.phase == .idle || cleanup.phase == .scanning ? nil : cleanup.groups.flatMap(\.items)
            .filter { cleanup.selected.contains($0.id) && ($0.mode == .delete || $0.mode == .emptyDir) }.reduce(0) { $0 + $1.size }
        var s = TodaySnapshot(diskFree: monitor.diskFree, diskTotal: monitor.diskTotal,
                             pressure: monitor.pressure, swapUsed: monitor.swapUsed, memTotal: monitor.memTotal,
                             externals: monitor.devices.filter { $0.kind == "drive" && $0.external && !$0.readOnly && $0.total > 0 },
                             trashSize: monitor.trashSize, reclaimable: reclaimable, pendingUpdates: Health.pendingUpdates,
                             movable: relocate.movable, dataVolumePlugged: Config.relocateTarget != nil)
        if DemoPublic.on { s.reclaimable = 6_300_000_000; s.trashSize = 4_200_000_000; s.pendingUpdates = nil }
        return s
    }

    var body: some View {
        let snap = snapshot
        let actions = TodayEngine.actions(snap)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.block) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Machine.name).font(Typo.pageTitle)
                    Text("\(Machine.model) · macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion) · démarré il y a \(Fmt.uptime(monitor.uptime))")
                        .font(Typo.detail).foregroundStyle(.secondary)
                }
                // Tuiles d'état : grille de colonnes égales (une par état), toutes de la même taille.
                let states = TodayEngine.states(snap)
                Grid(horizontalSpacing: Space.gap, verticalSpacing: Space.gap) {
                    GridRow {
                        ForEach(states) { st in
                            Button { Router.shared.go(st.target) } label: {
                                Tile(title: st.title, value: st.value, footer: st.detail, state: (st.level.label, color(st.level)), gauge: st.gauge)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                TodayFacts(reclaimable: snap.reclaimable)
                Text("Actions").font(Typo.sectionTitle).padding(.top, 4)
                // Panneau de hauteur fixe (3 lignes réservées) : la page ne bouge pas selon le nombre d'actions.
                VStack(spacing: 0) {
                    if actions.isEmpty {
                        Text("Aucune action à proposer.").font(Typo.detail).foregroundStyle(Palette.inkSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    ForEach(Array(actions.enumerated()), id: \.element.id) { n, a in
                        if n > 0 { Divider().opacity(0.4) }
                        HStack(spacing: Space.gap) {
                            StatePill(color: color(a.level), size: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.title).font(Typo.headline).lineLimit(1)
                                if !a.detail.isEmpty { Text(a.detail).font(Typo.detail).foregroundStyle(Palette.inkSecondary).lineLimit(1) }
                            }
                            Spacer()
                            Button(a.button) { run(a) }
                        }
                        .frame(height: Self.actionRow)
                    }
                    if !actions.isEmpty { Spacer(minLength: 0) }
                }
                .padding(.horizontal, Space.panel).padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: Self.actionsHeight, maxHeight: Self.actionsHeight, alignment: .top)
                .themePanel()
            }
            .padding(Space.page)
        }
        .onShow { refreshBackup(); relocate.refresh() }
        .onChange(of: monitor.devices) { _, _ in refreshBackup() }
    }

    static let actionRow: CGFloat = 58
    static let actionsHeight: CGFloat = actionRow * CGFloat(Thresholds.maxActions) + 14

    func color(_ l: Level) -> Color { l == .green ? Palette.grass : (l == .orange ? Palette.warn : Palette.alert) }

    func refreshBackup() {
    }

    func run(_ a: TodayAction) {
        if a.startsCleanupScan { AppSessions.cleanup.scan() }
        if let t = a.tab {
            if a.target == .cleanup { AppSessions.cleanup.focusedGroup = t }
            Router.shared.tabs[a.target] = t
        }
        Router.shared.go(a.target)
    }
}

/// Sous les tuiles : trois repères factuels de même taille (dernier nettoyage, espace récupérable, accès complet au disque), chacun avec
/// au plus un bouton. Lus hors du fil principal (estimation gardée 15 min), rien ne tourne quand la page est cachée.
struct TodayFacts: View {
    let reclaimable: Int64?
    @ObservedObject var activity = ActivityStore.shared
    let access = Perms.Access.shared
    @Local private var estimate: Int64?

    /// Modules dont une entrée du Journal est un nettoyage.
    static let cleaning: Set<String> = ["Nettoyage", "Mon désordre", "Corbeille", "Restes d'apps", "Installateurs", "Nettoyage du cloud", "Applications"]

    var body: some View {
        let last = activity.entries.first { Self.cleaning.contains($0.module) }
        Grid(horizontalSpacing: Space.gap, verticalSpacing: Space.gap) {
            GridRow {
                FactCell(title: "Dernier nettoyage", value: last.map { Fmt.ago($0.date) } ?? "Aucun",
                         detail: last.map { "\($0.module) · \(Fmt.bytes($0.bytes))" } ?? "Rien n'a encore été supprimé par zerOS")
                FactCell(title: "Espace récupérable", value: reclaimable.map(Fmt.bytes) ?? estimate.map { "≈ " + Fmt.bytes($0) } ?? "—",
                         detail: reclaimable != nil ? "caches régénérables cochés, mesurés" : "caches et journaux, estimation",
                         button: "Nettoyage") { Router.shared.go(.cleanup) }
                FactCell(title: "Accès complet au disque", value: access.fullDisk ? "Accordé" : "Non accordé",
                         detail: access.fullDisk ? "Mail, Safari et la Corbeille sont analysés" : "Mail, Safari et la Corbeille restent vides",
                         button: access.fullDisk ? nil : "Ouvrir les réglages", warn: !access.fullDisk) { Perms.openFullDiskAccess() }
            }
        }
        .onShow { load() }
    }

    func load() {
        if let c = Self.cache, Date().timeIntervalSince(c.at) < 900 { if estimate != c.bytes { estimate = c.bytes }; return }
        Task {
            let b = await Task.detached(priority: .utility) { FS.allocatedSize(FS.lib("Caches")) + FS.allocatedSize(FS.lib("Logs")) }.value
            Self.cache = (Date(), b)
            if estimate != b { estimate = b }
        }
    }

    @MainActor static var cache: (at: Date, bytes: Int64)?
}

/// Repère d'Aujourd'hui : titre, chiffre, détail, bouton facultatif ; hauteur fixe (la page ne bouge pas selon le contenu).
struct FactCell: View {
    let title: String
    let value: String
    let detail: String
    var button: String? = nil
    var warn = false
    var action: () -> Void = {}
    static let height: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Typo.caption).foregroundStyle(Palette.inkSecondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline) {
                Text(value).font(Typo.headline).monospacedDigit().foregroundStyle(warn ? Palette.warn : Palette.ink).lineLimit(1)
                Spacer(minLength: 4)
                if let button { Button(button, action: action).controlSize(.small) }
            }
            Spacer(minLength: 0)
            Text(detail).font(Typo.caption).foregroundStyle(Palette.inkSecondary).lineLimit(1).truncationMode(.tail).help(detail)
        }
        .padding(Space.panel)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .topLeading)
        .themePanel()
        .accessibilityElement(children: .combine)
    }
}
