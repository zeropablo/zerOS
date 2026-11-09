import SwiftUI
import AppKit

struct PerformanceView: View {
    let router = Router.shared
    var body: some View {
        let tab = router.tab(.performance, default: "health")
        Group {
            switch tab.wrappedValue {
            case "snapshots": SnapshotsView()
            case "tasks": MaintenanceView()
            default: HealthView()
            }
        }
        .moduleTabs([("health", "État"), ("tasks", "Réparations"), ("snapshots", "Instantanés")], selection: tab)
    }
}

// MARK: - Maintenance

@MainActor
final class MaintenanceModel: ObservableObject {
    static let shared = MaintenanceModel()
    @Published var selected: Set<String> = []
    @Published var running = false
    @Published var status = ""
    @Published var lastResult: String?


    func run() {
        let tasks = Maintenance.all.filter { selected.contains($0.id) }
        guard !tasks.isEmpty else { return }
        running = true
        lastResult = nil
        let rep = Reporter { s in Task { @MainActor in MaintenanceModel.shared.status = s } }
        Task {
            let r = await Task.detached { Maintenance.run(tasks, rep: rep) }.value
            for id in r.done { ActivityStore.shared.markRun("task." + id) }
            ActivityStore.shared.log(module: "Performance", text: Fmt.count(r.done.count, "tâche d'entretien", "tâches d'entretien"), bytes: r.freed)
            var msg = "\(Fmt.count(r.done.count, "tâche terminée", "tâches terminées"))"
            if r.freed > 0 { msg += " · \(Fmt.bytes(r.freed)) récupérés" }
            if !r.errors.isEmpty { msg += "\n" + r.errors.joined(separator: "\n") }
            lastResult = msg
            running = false
            selected = []
        }
    }
}

struct MaintenanceView: View {
    @ObservedObject var model = MaintenanceModel.shared
    @ObservedObject var store = ActivityStore.shared
    var body: some View {
        Form {
            Section {
                ForEach(Maintenance.all) { t in
                    Toggle(isOn: Binding(get: { model.selected.contains(t.id) },
                                         set: { if $0 { model.selected.insert(t.id) } else { model.selected.remove(t.id) } })) {
                        HStack(spacing: 12) {
                            SymbolTile(symbol: t.symbol, color: Module.performance.tint, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(t.title)
                                    if t.admin { Image(systemName: "lock").font(Typo.caption).foregroundStyle(.secondary).help("Demande le mot de passe administrateur") }
                                }
                                Text(t.detail).font(Typo.detail).foregroundStyle(.secondary)
                                Text("Dernière fois : \(Fmt.ago(store.lastRun["task." + t.id]))").font(Typo.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            } header: { Text("Réparations") } footer: {
                Text("À lancer seulement en cas de souci. Rien n'est coché : sur un Mac à puce Apple, macOS fait déjà son propre entretien.")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FloatingBar {
                if model.running { LiquidRing(size: 18); Text(model.status).foregroundStyle(.secondary).lineLimit(1) }
                else if let r = model.lastResult { Label(r, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(3) }
                Spacer()
                PrimaryButton(title: "Lancer \(Fmt.count(model.selected.count, "tâche"))", symbol: "play.fill",
                              disabled: model.selected.isEmpty || model.running) { model.run() }
            }
        }
    }
}

// MARK: - Démarrage et arrière-plan : cache

/// Apps > Démarrage et Arrière-plan : listes gardées en mémoire tant que la fenêtre est ouverte et sur disque entre deux lancements
/// (`startup.json`), affichées tout de suite. Relues en arrière-plan seulement si elles ont plus de 5 min ou si un dossier LaunchAgents /
/// LaunchDaemons ou la base des éléments de connexion a changé (dates de modification) ; une liste identique n'est pas reposée, seules
/// les lignes qui changent bougent.
@MainActor
final class StartupModel: ObservableObject {
    static let shared = StartupModel()
    enum Kind: String, Codable { case login, background }
    struct Orphan: Codable, Hashable { let item: BackgroundItem; let why: String }
    private struct Saved: Codable {
        var login: [LoginItem]?, background: [BackgroundItem]?, orphans: [Orphan]?
        var dates: [Kind: Date] = [:], stamps: [Kind: [Double]] = [:]
    }

    @Published private(set) var login: [LoginItem]?
    @Published private(set) var background: [BackgroundItem]?
    @Published private(set) var orphans: [Orphan]?
    private var saved = Saved()
    private var diskRead = false
    private var running: Set<Kind> = []
    nonisolated static let maxAge: TimeInterval = 300

    nonisolated static var url: URL { FS.support.appendingPathComponent("startup.json") }

    /// Dates de modification de ce qui fait changer la liste (un dossier illisible compte pour 0 : il ne déclenche rien).
    nonisolated static func stamp(_ k: Kind) -> [Double] {
        let paths = k == .login
            ? [FS.lib("Application Support/com.apple.backgroundtaskmanagementagent").path, "/private/var/db/com.apple.backgroundtaskmanagement"]
            : [FS.lib("LaunchAgents").path, "/Library/LaunchAgents", "/Library/LaunchDaemons"]
        return paths.map { p in var st = stat(); return stat(p, &st) == 0 ? Double(st.st_mtimespec.tv_sec) : 0 }
    }

    /// Montre la liste (cache) et la relit en arrière-plan si besoin. `force` : bouton Actualiser, ou après un changement fait par zerOS.
    func show(_ k: Kind, force: Bool = false) {
        guard !running.contains(k) else { return }
        running.insert(k)
        let first = !diskRead
        diskRead = true
        let (date, stamp) = (saved.dates[k], saved.stamps[k])
        Task.detached(priority: .utility) {
            var (d0, s0) = (date, stamp)
            if first, let d = try? Data(contentsOf: Self.url), let s = try? JSONDecoder().decode(Saved.self, from: d) {
                await MainActor.run { StartupModel.shared.restore(s) }
                (d0, s0) = (s.dates[k], s.stamps[k])
            }
            let now = Self.stamp(k)
            if !force, let d0, Date().timeIntervalSince(d0) < Self.maxAge, s0 == now {
                await MainActor.run { _ = StartupModel.shared.running.remove(k) }
                return
            }
            switch k {
            case .login:
                let l = LoginItems.list()
                await MainActor.run { StartupModel.shared.apply(k, stamp: now) { $0.login = l } }
            case .background:
                let l = BackgroundItems.list()
                await MainActor.run { StartupModel.shared.apply(k, stamp: now, final: false) { $0.background = l } }
                let o = (Services.orphans(items: l) + Services.probableOrphans(items: l)).map { Orphan(item: $0.item, why: $0.why) }
                await MainActor.run { StartupModel.shared.apply(k, stamp: now) { $0.orphans = o } }
            }
        }
    }

    private func restore(_ s: Saved) {
        saved.dates.merge(s.dates) { a, _ in a }
        saved.stamps.merge(s.stamps) { a, _ in a }
        if saved.login == nil { saved.login = s.login }
        if saved.background == nil { saved.background = s.background; saved.orphans = s.orphans }
        publish()
    }

    /// Nouveau relevé : gardé et enregistré ; posé à l'écran (après la transition en cours) seulement s'il diffère de l'affiché.
    private func apply(_ k: Kind, stamp: [Double], final: Bool = true, _ change: (inout Saved) -> Void) {
        change(&saved)
        guard final else { publish(); return }
        saved.dates[k] = Date(); saved.stamps[k] = stamp
        running.remove(k)
        publish()
        let s = saved
        Task.detached(priority: .utility) { if let d = try? JSONEncoder().encode(s) { try? d.write(to: Self.url, options: .atomic) } }
    }

    private func publish() {
        Settle.shared.whenShown(.apps) {
            let m = StartupModel.shared
            if m.login != m.saved.login { m.login = m.saved.login }
            if m.background != m.saved.background { m.background = m.saved.background }
            if m.orphans != m.saved.orphans { m.orphans = m.saved.orphans }
        }
    }

    /// Fenêtre fermée : listes rendues (relues depuis le disque à la réouverture). Pas pendant une relecture.
    func release() {
        guard running.isEmpty else { return }
        login = nil; background = nil; orphans = nil
        saved = Saved(); diskRead = false
    }
}

// MARK: - Login items

struct LoginItemsView: View {
    @ObservedObject var m = StartupModel.shared
    var body: some View {
        Form {
            Section {
                if let items = m.login {
                    if items.isEmpty {
                        Text("Aucune app ouverte au démarrage, ou autorisation de contrôler « Événements Système » pas encore accordée.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { i in
                        Toggle(isOn: Binding(get: { i.enabled }, set: { on in
                            Task.detached { _ = LoginItems.setEnabled(i, on); await MainActor.run { StartupModel.shared.show(.login, force: true) } }
                        })) {
                            HStack(spacing: 10) {
                                ItemIcon(path: i.path.isEmpty ? nil : i.path, symbol: "app", size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(i.name)
                                    Text(i.path).font(Typo.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                    }
                } else { HStack { Spacer(); LiquidRing(size: 32); Spacer() } }
            } header: { Text("Ouverture au démarrage") } footer: {
                Text("Les apps qui s'ouvrent toutes seules quand vous allumez le Mac. Moins il y en a, plus le démarrage est rapide.")
            }
        }
        .formStyle(.grouped)
        .pageActions {
            Button("Réglages d'ouverture") { Perms.openLoginItems() }
            Button { m.show(.login, force: true) } label: { Label("Actualiser", systemImage: "arrow.clockwise") }.help("Actualiser")
        }
        .onShow { m.show(.login) }
    }
}

// MARK: - Background items

struct BackgroundItemsView: View {
    @ObservedObject var m = StartupModel.shared
    @Local private var query = ""
    @Local private var busy: String?
    @Local private var menuFor: String?
    @Local private var removing: BackgroundItem?

    /// Liste paresseuse en SwiftUI pur (plus de `Form` : un interrupteur et un menu AppKit par ligne coûtaient 96 à 138 ms de mise en
    /// page à chaque affichage, mesuré rc2) ; interrupteur dessiné, menu de ligne en popover construit seulement à l'ouverture.
    var body: some View {
        let items = m.background ?? []
        let filtered = query.isEmpty ? items : items.filter { $0.displayName.localizedCaseInsensitiveContains(query) || $0.label.localizedCaseInsensitiveContains(query) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Petits programmes qui tournent en permanence (mises à jour automatiques, assistants…). Désactivez ceux dont vous n'avez pas besoin.")
                    .foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8)
                header("Services orphelins")
                if let orphans = m.orphans {
                    if orphans.isEmpty { Text("Aucun service orphelin.").foregroundStyle(.secondary).lazyRow() }
                    ForEach(orphans, id: \.item.id) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.item.label).fontWeight(.medium)
                            Text("\(f.item.scope.rawValue) · \(f.why)").font(Typo.detail).foregroundStyle(.secondary)
                            Text(f.item.plist.path.replacingOccurrences(of: FS.home.path, with: "~")).font(Typo.caption).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lazyRow()
                    }
                } else {
                    HStack { LiquidRing(size: 18); Text("Recherche des services orphelins…").foregroundStyle(.secondary) }.lazyRow()
                }
                Text("Lecture seule. « Programme introuvable » : l'app a été supprimée. « Orphelin probable » : aucune app installée du même éditeur ni du même Team ID.")
                    .font(Typo.detail).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 4)
                if m.background == nil { HStack { Spacer(); LiquidRing(size: 32); Spacer() }.padding(.top, 16) }
                ForEach([BackgroundItem.Scope.user, .allUsers, .system], id: \.self) { scope in
                    let list = filtered.filter { $0.scope == scope }
                    if !list.isEmpty {
                        header(scope.rawValue)
                        ForEach(list) { i in row(i) }
                    }
                }
            }
            .padding(.vertical, 8).padding(.bottom, Radius.panel)
        }
        .scrollEdgeFade()
        .pageActions(search: $query) {
            Button { m.show(.background, force: true) } label: { Label("Actualiser", systemImage: "arrow.clockwise") }.help("Actualiser")
        }
        .onShow { m.show(.background) }
        .alert("Mettre ce lanceur à la Corbeille ?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Annuler", role: .cancel) { removing = nil }
            Button("Mettre à la Corbeille", role: .destructive) { if let i = removing { act(i) { _ = BackgroundItems.remove(i) } }; removing = nil }
        } message: {
            Text(removing.map { "\($0.displayName) (\($0.label)), \(Fmt.bytes(FS.allocatedSize($0.plist))) : arrêté, puis mis à la Corbeille (récupérable)." + ($0.scope == .user ? "" : " Mot de passe administrateur demandé.") } ?? "")
        }
    }

    func header(_ t: String) -> some View {
        Text(t).font(Typo.headline).padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
    }

    func row(_ i: BackgroundItem) -> some View {
        HStack(spacing: 10) {
            ItemIcon(path: i.ownerApp?.path, symbol: "gearshape.2", size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(i.displayName).lineLimit(1)
                Text(i.label).font(Typo.detail).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if busy == i.id { LiquidRing(size: 18) }
            if i.scope != .user { Image(systemName: "lock").foregroundStyle(.secondary).help("Demande le mot de passe administrateur") }
            Button { menuFor = i.id } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Plus d'actions")
                .popover(isPresented: Binding(get: { menuFor == i.id }, set: { if !$0 { menuFor = nil } })) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Afficher dans le Finder") { menuFor = nil; FS.reveal(i.plist) }
                        Button("Mettre ce lanceur à la Corbeille…", role: .destructive) { menuFor = nil; removing = i }
                    }
                    .buttonStyle(.borderless).padding(14)
                }
            LightSwitch(on: i.enabled, disabled: busy == i.id) { let on = !i.enabled; act(i) { _ = BackgroundItems.setEnabled(i, on) } }
        }
        .lazyRow()
    }

    func act(_ i: BackgroundItem, _ work: @escaping @Sendable () -> Void) {
        busy = i.id
        Task.detached { work(); await MainActor.run { busy = nil; StartupModel.shared.show(.background, force: true) } }
    }
}

// MARK: - Time Machine snapshots

struct SnapshotsView: View {
    @Local private var snaps: [LocalSnapshot] = []
    @Local private var selected: Set<String> = []
    @Local private var busy = false
    @Local private var confirm = false
    var body: some View {
        Form {
            Section {
                if snaps.isEmpty {
                    Label("Aucun instantané local sur ce Mac", systemImage: "checkmark.seal").foregroundStyle(.secondary)
                }
                ForEach(snaps) { s in
                    Toggle(isOn: Binding(get: { selected.contains(s.id) }, set: { if $0 { selected.insert(s.id) } else { selected.remove(s.id) } })) {
                        LabeledContent { Text(s.name).foregroundStyle(.secondary) } label: {
                            Label(Fmt.dateTime(s.date), systemImage: "clock.arrow.2.circlepath")
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            } header: { Text("Instantanés Time Machine") } footer: {
                Text("Time Machine garde des copies de secours sur le disque interne en attendant votre disque de sauvegarde. Elles peuvent prendre beaucoup de place ; vos vraies sauvegardes ne sont pas touchées.")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !snaps.isEmpty {
                FloatingBar {
                    Button("Tout sélectionner") { selected = Set(snaps.map(\.id)) }
                    Spacer()
                    if busy { LiquidRing(size: 18) }
                    PrimaryButton(title: "Supprimer \(selected.count)", symbol: "trash", disabled: selected.isEmpty || busy) { confirm = true }
                }
            }
        }
        .alert("Supprimer \(Fmt.count(selected.count, "instantané local", "instantanés locaux")) ?", isPresented: $confirm) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer", role: .destructive) { deleteSelected() }
        } message: {
            Text(snaps.filter { selected.contains($0.id) }.prefix(8).map { "· " + Fmt.dateTime($0.date) }.joined(separator: "\n")
                 + "\n\nIrréversible. Ce sont des copies temporaires que macOS gère et recrée seul ; vos sauvegardes Time Machine sur disque ne sont pas touchées. Mot de passe administrateur demandé.")
        }
        .onAppear(perform: load)
    }

    func deleteSelected() {
        busy = true
        let chosen = snaps.filter { selected.contains($0.id) }
        Task.detached {
            let before = FS.volumeFree
            let ok = Snapshots.delete(chosen)
            let freed = max(0, FS.volumeFree - before)
            await MainActor.run {
                if ok { ActivityStore.shared.log(module: "Performance", text: "\(chosen.count) instantané(s) Time Machine supprimé(s)", bytes: freed) }
                busy = false; selected = []; load()
            }
        }
    }

    func load() { Task.detached { let s = Snapshots.list(); await MainActor.run { snaps = s } } }
}
