import SwiftUI
import AppKit

struct ApplicationsView: View {
    let router = Router.shared
    var body: some View {
        let tab = router.tab(.applications, default: "uninstall")
        TabDeck(tabs: [("uninstall", "Désinstallation"), ("updates", "Mises à jour"), ("leftovers", "Restes"), ("login", "Démarrage"), ("background", "Arrière-plan"), ("installers", "Installateurs")],
                selection: tab.wrappedValue, select: { tab.wrappedValue = $0 }) { id in
            switch id {
            case "updates": UpdatesView()
            case "leftovers": LeftoversView()
            case "login": LoginItemsView()
            case "background": BackgroundItemsView()
            case "installers":
                SessionPage(module: .applications, session: AppSessions.installers, heroTitle: "Fichiers d'installation",
                            heroText: "Les .dmg et .pkg qui traînent une fois l'app installée.")
            default: UninstallerView()
            }
        }
    }
}

// MARK: - Uninstaller

@MainActor
final class AppsModel: ObservableObject {
    static let shared = AppsModel()
    @Published var apps: [AppInfo] = []
    @Published var loading = false
    @Published var status = ""
    @Published var focused: AppInfo?
    @Published var related: [CleanItem] = []
    @Published var relatedSelected: Set<UUID> = []
    @Published var checked: Set<String> = []
    @Published var filter = "all"
    @Published var sort = "size"
    @Published var query = ""
    @Published var working = false
    @Published var lastReport: CleanReport?

    var visible: [AppInfo] {
        let sixMonths = Date().addingTimeInterval(-182 * 86400)
        var list = apps.filter { a in
            switch filter {
            case "unused": return (a.lastUsed ?? .distantPast) < sixMonths
            case "store": return a.isAppStore
            case "other": return !a.isAppStore && !a.isApple
            default: return true
            }
        }
        if !query.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        switch sort {
        case "name": list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case "used": list.sort { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        default: list.sort { $0.size > $1.size }
        }
        return list
    }

    func load() {
        loading = true
        Task.detached {
            // 1) La liste avec les tailles déjà connues (cache sur disque, app inchangée depuis), 2) les autres mesurées, posées en une fois.
            if DemoPublic.on {
                let list = DemoPublic.apps
                await MainActor.run { Settle.shared.whenShown(.apps) { AppsModel.shared.apps = list; AppsModel.shared.loading = false } }
                return
            }
            let known = Self.readSizes()
            var quick = AppCatalog.appURLs().compactMap { AppCatalog.info($0, withSize: false) }
            var stamps: [String: Double] = [:]
            for i in quick.indices {
                let st = Self.stamp(quick[i].url)
                stamps[quick[i].id] = st
                if let e = known[quick[i].id], e.stamp == st { quick[i].size = e.size }
            }
            let list = quick
            await MainActor.run { Settle.shared.whenShown(.apps) { AppsModel.shared.apps = list; AppsModel.shared.loading = false } }
            let unused = list.filter { ($0.lastUsed ?? .distantPast) < Date().addingTimeInterval(-182 * 86400) }.count
            await MainActor.run { Health.unusedApps = unused }
            var measured: [String: Int64] = [:]
            await withTaskGroup(of: (String, Int64).self) { g in
                for a in list where a.size == 0 { g.addTask { (a.id, FS.allocatedSize(a.url)) } }
                for await (id, size) in g { measured[id] = size }
            }
            if !measured.isEmpty {
                let m2 = measured
                await MainActor.run {
                    Settle.shared.whenShown(.apps) {
                        let m = AppsModel.shared
                        // Liste pas encore posée (transition en cours) : elle l'est ici, tailles comprises.
                        if m.apps.isEmpty { m.apps = list.map { var a = $0; if let s = m2[a.id] { a.size = s }; return a }; m.loading = false }
                        // Une seule affectation (une seule notification), pas une par app.
                        m.apps = m.apps.map { var a = $0; if let s = m2[a.id] { a.size = s }; return a }
                        if let f = m.focused, let s = m2[f.id] { m.focused?.size = s }
                    }
                }
            }
            var out: [String: SizeEntry] = [:]
            for a in list { let s = measured[a.id] ?? a.size; if s > 0, let st = stamps[a.id] { out[a.id] = SizeEntry(stamp: st, size: s) } }
            if let data = try? JSONEncoder().encode(out) { try? data.write(to: Self.sizesURL, options: .atomic) }
        }
    }

    /// Tailles des apps gardées sur disque avec la date de modification de l'app (et de son Info.plist, qui change à chaque mise à jour) :
    /// une app inchangée n'est jamais remesurée.
    struct SizeEntry: Codable { let stamp: Double; let size: Int64 }
    nonisolated static var sizesURL: URL { FS.support.appendingPathComponent("app-sizes.json") }
    nonisolated static func readSizes() -> [String: SizeEntry] {
        (try? Data(contentsOf: sizesURL)).flatMap { try? JSONDecoder().decode([String: SizeEntry].self, from: $0) } ?? [:]
    }
    nonisolated static func stamp(_ u: URL) -> Double {
        func m(_ x: URL) -> Double { (try? x.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0 }
        return max(m(u), m(u.appendingPathComponent("Contents/Info.plist")))
    }

    /// Fenêtre fermée : liste, détail et cases cochées sont rendus (la liste est relue à la réouverture de l'onglet).
    func release() {
        guard !working, !loading else { return }
        apps = []; focused = nil; related = []; relatedSelected = []; checked = []
    }

    /// Clavier ↑↓ : app précédente ou suivante dans la liste affichée (bornée ; la liste la fait venir à l'écran).
    func step(_ d: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == focused?.id }.map { min(list.count - 1, max(0, $0 + d)) } ?? 0
        if list[i].id != focused?.id { focus(list[i]) }
    }

    func focus(_ a: AppInfo) {
        focused = a
        related = []
        Task.detached {
            let r = AppCatalog.relatedFiles(for: a)
            await MainActor.run {
                guard AppsModel.shared.focused?.id == a.id else { return }
                AppsModel.shared.related = r
                AppsModel.shared.relatedSelected = Set(r.filter(\.preselected).map(\.id))
            }
        }
    }

    func uninstall(_ targets: [AppInfo], keepApp: Bool) {
        working = true
        let single = targets.count == 1 && targets.first?.id == focused?.id
        let chosen = related.filter { relatedSelected.contains($0.id) }
        Task.detached {
            var total = CleanReport()
            for a in targets {
                let files = single ? chosen : AppCatalog.relatedFiles(for: a).filter(\.preselected)
                let r = AppCatalog.uninstall(a, files: files, keepApp: keepApp)
                total.freed += r.freed; total.count += r.count; total.errors += r.errors
            }
            let total2 = total
            await MainActor.run {
                let total = total2
                let m = AppsModel.shared
                ActivityStore.shared.log(module: "Applications",
                                         text: keepApp ? "Réinitialisation de \(targets.map(\.name).joined(separator: ", "))" : "Désinstallation de \(targets.map(\.name).joined(separator: ", "))",
                                         bytes: total.freed)
                m.lastReport = total
                m.working = false
                m.checked = []
                if !keepApp { m.apps.removeAll { a in targets.contains { $0.id == a.id } }; m.focused = nil }
                else if let f = m.focused { m.focus(f) }
            }
        }
    }
}

struct UninstallerView: View {
    @ObservedObject var m = AppsModel.shared
    @Local private var confirm: (apps: [AppInfo], keep: Bool)?
    @FocusState private var listFocused: Bool

    var body: some View {
        let list = m.visible
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Picker("Afficher", selection: $m.filter) {
                        Text("Toutes").tag("all"); Text("Inutilisées").tag("unused"); Text("App Store").tag("store"); Text("Autres").tag("other")
                    }.pickerStyle(.segmented).labelsHidden()
                    Picker("Trier par", selection: $m.sort) {
                        Text("Taille").tag("size"); Text("Nom").tag("name"); Text("Dernière utilisation").tag("used")
                    }
                }
                .padding(Space.gap)
                Deferred {
                if m.loading && m.apps.isEmpty {
                    LiquidRing(size: 48).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if list.isEmpty {
                    EmptyState(m.query.isEmpty ? "Aucune app dans ce filtre" : "Aucune app ne correspond à « \(m.query) »", symbol: "square.grid.2x2")
                } else {
                    // Liste paresseuse en SwiftUI pur : seules les lignes visibles sont construites, aucune vue AppKit par ligne.
                    // Clavier : ↑↓ changent l'app choisie (après un clic dans la liste), la liste suit.
                    ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(list) { a in
                                HStack(spacing: 10) {
                                    Checkbox(state: m.checked.contains(a.id)) { if m.checked.contains(a.id) { m.checked.remove(a.id) } else { m.checked.insert(a.id) } }
                                    ItemIcon(path: a.url.path, symbol: "app", size: 28)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(a.name).lineLimit(1)
                                        Text("Utilisée \(Fmt.ago(a.lastUsed))").font(Typo.detail).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(a.size > 0 ? Fmt.bytes(a.size) : "…").monospacedDigit().foregroundStyle(.secondary)
                                }
                                .lazyRow(selected: m.focused?.id == a.id)
                                .id(a.id)
                                .onTapGesture { listFocused = true; m.focus(a) }
                                .accessibilityAddTraits(m.focused?.id == a.id ? [.isSelected, .isButton] : .isButton)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollEdgeFade()
                    .focusable().focused($listFocused).focusEffectDisabled()
                    .onKeyPress(.upArrow) { m.step(-1); return .handled }
                    .onKeyPress(.downArrow) { m.step(1); return .handled }
                    .onChange(of: m.focused?.id) { _, id in if let id { withAnimation(Motion.detail) { proxy.scrollTo(id) } } }
                    }
                    .animation(Motion.detail, value: m.filter)
                    .animation(Motion.detail, value: m.sort)
                    .animation(Motion.detail, value: m.query)
                }
                }
                Divider()
                HStack {
                    Text(Fmt.count(list.count, "app")).foregroundStyle(.secondary)
                    Spacer()
                    Button("Désinstaller \(m.checked.count)") { confirm = (m.apps.filter { m.checked.contains($0.id) }, false) }
                        .disabled(m.checked.isEmpty || m.working)
                }
                .padding(Space.gap)
            }
            .frame(width: 360)
            .themePanel()

            Deferred { detail }.themePanel()
        }
        .padding(Space.gap)
        .pageActions(search: $m.query, prompt: "Rechercher une app") { EmptyView() }
        .onShow { if m.apps.isEmpty && !m.loading { m.load() } }
        .alert(confirm?.keep == true ? "Réinitialiser l'app ?" : "Désinstaller ?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Annuler", role: .cancel) { confirm = nil }
            Button(confirm?.keep == true ? "Réinitialiser" : "Désinstaller", role: .destructive) {
                if let c = confirm { m.uninstall(c.apps, keepApp: c.keep) }
                confirm = nil
            }
        } message: {
            Text(confirm?.keep == true
                 ? "Fichiers cochés à la Corbeille (récupérables) : \(chosenLine). L'app reste installée, comme neuve."
                 : confirmText(confirm?.apps ?? []))
        }
    }

    var chosenLine: String {
        let f = m.related.filter { m.relatedSelected.contains($0.id) }
        return "\(Fmt.count(f.count, "fichier")), \(Fmt.bytes(f.reduce(0) { $0 + $1.size }))"
    }

    /// Confirmation de la désinstallation : apps et fichiers liés cochés, nombre et taille, tout à la Corbeille.
    func confirmText(_ apps: [AppInfo]) -> String {
        let names = apps.prefix(8).map { "· \($0.name) — \(Fmt.bytes($0.size))" }.joined(separator: "\n") + (apps.count > 8 ? "\n… et \(apps.count - 8) autre(s)" : "")
        let files = apps.count == 1 && apps.first?.id == m.focused?.id
            ? "Fichiers liés cochés : \(chosenLine)."
            : "Fichiers liés : seulement leurs caches (recréés seuls) ; les autres restent, visibles ensuite dans Restes d'apps."
        return "\(Fmt.count(apps.count, "app")), \(Fmt.bytes(apps.reduce(0) { $0 + $1.size })) :\n\(names)\n\n\(files)\nTout va à la Corbeille (récupérable). Les apps ouvertes seront fermées ; un mot de passe administrateur peut être demandé pour les fichiers système."
    }

    @ViewBuilder var detail: some View {
        if m.working {
            BusyView(module: .applications, title: "Désinstallation…", status: "")
        } else if let a = m.focused {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 16) {
                        ItemIcon(path: a.url.path, symbol: "app", size: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(a.name).font(Typo.pageTitle)
                            Text("Version \(a.version)\(a.isAppStore ? " · App Store" : "")").foregroundStyle(.secondary)
                            Text("Dernière utilisation : \(Fmt.ago(a.lastUsed))").font(Typo.detail).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Grid(horizontalSpacing: Space.gap) {
                        GridRow {
                            stat("App", Fmt.bytes(a.size), "le paquet de l'app")
                            stat("Fichiers liés", Fmt.bytes(m.related.reduce(0) { $0 + $1.size }), Fmt.count(m.related.count, "fichier trouvé", "fichiers trouvés"))
                            stat("Total", Fmt.bytes(a.size + m.related.filter { m.relatedSelected.contains($0.id) }.reduce(0) { $0 + $1.size }), "ce qui partira à la Corbeille")
                        }
                    }
                    Text("Fichiers liés à l'app").font(Typo.sectionTitle)
                }
                .padding([.horizontal, .top], Space.page).padding(.bottom, 8)
                List {
                    if m.related.isEmpty { Text("Aucun fichier lié trouvé.").foregroundStyle(.secondary) }
                    ForEach(m.related) { f in
                        HStack(spacing: 10) {
                            Checkbox(state: m.relatedSelected.contains(f.id)) {
                                if m.relatedSelected.contains(f.id) { m.relatedSelected.remove(f.id) } else { m.relatedSelected.insert(f.id) }
                            }
                            Image(systemName: f.symbol ?? "folder").foregroundStyle(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.title).lineLimit(1).truncationMode(.middle)
                                Text(f.subtitle).font(Typo.detail).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Fmt.bytes(f.size)).monospacedDigit()
                            if let u = f.url { Button { FS.reveal(u) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Afficher dans le Finder") }
                        }
                        .themeRow()
                    }
                    if let r = m.lastReport, !r.errors.isEmpty {
                        Text(r.errors.joined(separator: "\n")).font(Typo.detail).foregroundStyle(.orange)
                    }
                }
                .listStyle(.inset)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FloatingBar {
                    Button("Réinitialiser") { confirm = ([a], true) }.controlSize(.large).disabled(m.relatedSelected.isEmpty)
                        .help("Efface les réglages et données, garde l'app")
                    Spacer()
                    PrimaryButton(title: "Désinstaller", symbol: "trash") { confirm = ([a], false) }
                }
            }
        } else {
            EmptyState("Aucune app sélectionnée",
                       detail: "Une app choisie dans la liste montre sa taille et tous ses fichiers liés." + (m.lastReport.map { $0.freed > 0 ? "\nDernière désinstallation : \(Fmt.bytes($0.freed)) libérés." : "" } ?? ""),
                       symbol: "square.grid.2x2")
        }
    }

    func stat(_ t: String, _ v: String, _ footer: String) -> some View {
        Tile(title: t, value: v, footer: footer)
    }
}

// MARK: - Updates

@MainActor
final class UpdatesModel: ObservableObject {
    static let shared = UpdatesModel()
    @Published var updates: [AppUpdate] = []
    @Published var checking = false
    @Published var checkedAt: Date?
    @Published var state: [String: String] = [:]   // id → status
    @Published var macOS: [String]?
    @Published var checkingMac = false
    @Published var status = ""

    func check() {
        checking = true
        let rep = Reporter { s in Task { @MainActor in UpdatesModel.shared.status = s } }
        Task.detached {
            let u = await Updater.check(rep)
            await MainActor.run {
                let m = UpdatesModel.shared
                m.updates = u; m.checking = false; m.checkedAt = Date(); m.state = [:]
                Health.pendingUpdates = u.count
            }
        }
    }

    func install(_ list: [AppUpdate]) {
        for u in list { state[u.id] = "En attente…" }
        Task {
            for u in list {
                state[u.id] = "Installation…"
                let rep = Reporter { s in Task { @MainActor in UpdatesModel.shared.state[u.id] = s } }
                let err = await Updater.install(u, rep: rep)
                state[u.id] = err ?? "✓ À jour"
                if err == nil { ActivityStore.shared.log(module: "Applications", text: "\(u.appName) mis à jour en \(u.latest)", bytes: 0) }
            }
            Health.pendingUpdates = updates.filter { state[$0.id] != "✓ À jour" }.count
        }
    }

    func checkMac() {
        checkingMac = true
        Task.detached {
            let l = Updater.macOSUpdates()
            await MainActor.run { UpdatesModel.shared.macOS = l; UpdatesModel.shared.checkingMac = false }
        }
    }
}

struct UpdatesView: View {
    @ObservedObject var m = UpdatesModel.shared
    var body: some View {
        Form {
            Section {
                if m.checking {
                    HStack(spacing: 10) { LiquidRing(size: 18); Text(m.status).foregroundStyle(.secondary).lineLimit(1) }
                } else if m.checkedAt != nil && m.updates.isEmpty {
                    Label("Toutes vos apps sont à jour", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
                ForEach(m.updates) { u in
                    HStack(spacing: 12) {
                        ItemIcon(path: u.appURL?.path, symbol: "shippingbox", size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(u.appName)
                            Text("\(u.current) → \(u.latest)").font(Typo.detail).foregroundStyle(.secondary)
                        }
                        Spacer()
                        switch u.source {
                        case .brew: Text("Homebrew").font(Typo.caption).foregroundStyle(.secondary)
                        case .appStore: Text("App Store").font(Typo.caption).foregroundStyle(.secondary)
                        case .sparkle: EmptyView()
                        }
                        if let s = m.state[u.id] { Text(s).font(Typo.detail).foregroundStyle(s.hasPrefix("✓") ? .green : .secondary).lineLimit(2).frame(maxWidth: 260, alignment: .trailing) }
                        else { Button("Mettre à jour") { m.install([u]) } }
                    }
                }
            } header: {
                Text(m.checking ? "Recherche de mises à jour…" : (m.checkedAt == nil ? "Mises à jour des apps" : Fmt.count(m.updates.count, "mise à jour disponible", "mises à jour disponibles")))
            } footer: {
                Text("zerOS vérifie que le nouveau fichier vient bien du même développeur avant d'installer.")
            }

            Section("macOS et apps de l'App Store") {
                LabeledContent {
                    HStack {
                        if m.checkingMac { LiquidRing(size: 18) }
                        Button("Vérifier macOS") { m.checkMac() }.disabled(m.checkingMac)
                    }
                } label: {
                    Label { Text("macOS") } icon: { Image(systemName: "apple.logo") }
                    if let l = m.macOS { Text(l.isEmpty ? "macOS est à jour" : l.joined(separator: ", ")) }
                    else { Text("Vérification à la demande (prend environ une minute)") }
                }
                HStack {
                    Button("Ouvrir l'App Store") { NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!) }
                    Button("Réglages de mise à jour") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!) }
                }
            }
        }
        .formStyle(.grouped)
        .pageActions {
            Button { m.check() } label: { Label("Vérifier", systemImage: "arrow.clockwise") }.disabled(m.checking).help("Vérifier les mises à jour")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !m.updates.isEmpty {
                FloatingBar {
                    Text(Fmt.count(m.updates.count, "mise à jour", "mises à jour")).font(Typo.headline)
                    Spacer()
                    PrimaryButton(title: "Tout mettre à jour", symbol: "arrow.down.circle", disabled: m.checking) { m.install(m.updates) }
                }
            }
        }
        .onAppear { if m.checkedAt == nil && !m.checking { m.check() } }
    }
}

// MARK: - Leftovers

struct LeftoversView: View {
    @ObservedObject var session = AppSessions.leftovers
    @AppStorage("pendingLeftoverBundle") var pending = ""
    var body: some View {
        VStack(spacing: 0) {
            if !pending.isEmpty {
                GroupBox {
                HStack {
                    Image(systemName: "trash.circle.fill").foregroundStyle(.tint).font(.title2)
                    Text("Une app vient d'être mise à la Corbeille : \(pending). Analysez pour supprimer ses restes.")
                    Spacer()
                    Button("Analyser ses restes") {
                        let id = pending
                        let s = Sessions.shared.get("leftovers.\(id)", title: "Restes d'apps", configure: { $0.primaryTitle = "Supprimer" }) { rep in
                            let info = AppInfo(url: URL(fileURLWithPath: "/"), name: id.components(separatedBy: ".").last ?? id, bundleID: id, version: "", build: "", size: 0, lastUsed: nil, isAppStore: false, isApple: false, feedURL: nil)
                            let files = AppCatalog.relatedFiles(for: info)
                            return [CleanGroup(id: "pending", title: "Restes de \(info.name)", subtitle: id, symbol: "trash", items: files)]
                        }
                        session.load([])
                        session.phase = .scanning
                        Task { let g = await Task.detached { await s.scanner(.silent) }.value; session.load(g) }
                        pending = ""
                    }
                    Button("Ignorer") { pending = "" }
                }
                .padding(4)
                }
                .padding([.horizontal, .top], 16)
            }
            SessionPage(module: .applications, session: session, heroTitle: "Restes d'apps supprimées",
                        heroText: "Quand on jette une app dans la Corbeille, ses réglages, caches et données restent sur le Mac. zerOS les retrouve.")
        }
    }
}
