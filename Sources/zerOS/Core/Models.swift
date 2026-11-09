import Foundation
import SwiftUI

// MARK: - Items

enum RemovalMode: Hashable, Sendable {
    case delete          // removed for good (regenerable junk)
    case emptyDir        // folder kept, content removed
    case trash           // moved to the Trash (user files)
    case admin           // removed with the admin password (regenerable system junk only)
    case adminEmpty      // folder content removed with the admin password (regenerable system junk only)
    case adminTrash      // system-owned user data: moved to the user's Trash with the admin password (recoverable)
    case custom(String)  // handled by CustomActions
    case none            // shown for information only
}

struct CleanItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    var url: URL?
    var title: String
    var subtitle: String = ""
    var size: Int64 = 0
    var date: Date? = nil
    var mode: RemovalMode = .delete
    var preselected: Bool = true
    var payload: String = ""
    var iconPath: String? = nil
    var symbol: String? = nil
    /// Inside a read-only folder: shown, never selectable or removable (set by `ScanSession.load`).
    var readOnly = false
    /// Can be checked and removed.
    var actionable: Bool { mode != .none && !readOnly }
}

struct CleanGroup: Identifiable, Sendable {
    var id: String
    var title: String
    var subtitle: String = ""
    var symbol: String = "folder"
    var items: [CleanItem] = []
    var note: String? = nil
    var infoOnly = false
    var keepOne = false
    /// Caches et fichiers que macOS ou les apps recréent seuls (SECURITE-NETTOYAGE.md). Seul un groupe régénérable peut supprimer
    /// définitivement ou présélectionner ; tout autre groupe met à la Corbeille, rien coché.
    var regenerable = false
    var size: Int64 { items.reduce(0) { $0 + $1.size } }

    /// Règle 1.0, appliquée à tout groupe avant affichage et avant nettoyage (`ScanSession`) : hors groupe régénérable, aucune suppression
    /// définitive (→ Corbeille, ou analyse seule pour une action définitive sans équivalent) et rien de présélectionné. Puis lecture seule.
    func protected() -> CleanGroup {
        var g = self
        g.items = items.map { i in
            var i = Self.policy(i, regenerable: regenerable)
            // Exception (SPEC.md) : un dossier de cache lu dans les préférences Adobe reste vidable sur un volume en lecture seule.
            if let u = i.url, Ignore.readOnly(u), i.mode != .custom("prefsCache") { i.readOnly = true; i.preselected = false }
            return i
        }
        return g
    }

    static func policy(_ item: CleanItem, regenerable: Bool) -> CleanItem {
        guard !regenerable else { return item }
        var i = item
        i.preselected = false
        switch i.mode {
        case .delete, .emptyDir: i.mode = .trash
        case .admin, .adminEmpty: i.mode = .adminTrash
        case .custom(let k) where k != "evict": i.mode = .none
        default: break
        }
        return i
    }

    /// Suppression définitive (rien ne passe par la Corbeille).
    static func isDefinitive(_ m: RemovalMode) -> Bool {
        switch m {
        case .delete, .emptyDir, .admin, .adminEmpty: true
        case .custom(let k): k == "prefsCache"
        default: false
        }
    }
}

final class Reporter: @unchecked Sendable {
    private let handler: (String) -> Void
    private var last = Date.distantPast
    init(_ h: @escaping (String) -> Void) { handler = h }
    func callAsFunction(_ s: String) { handler(s) }
    /// Rate-limited update for tight loops.
    func tick(_ s: @autoclosure () -> String) {
        let now = Date()
        if now.timeIntervalSince(last) > 0.15 { last = now; handler(s()) }
    }
    static let silent = Reporter { _ in }
}

struct CleanReport: Sendable {
    var freed: Int64 = 0
    var count = 0
    var errors: [String] = []
}

typealias Scanner = @Sendable (Reporter) async -> [CleanGroup]

// MARK: - Cleaning engine

enum Cleaner {
    static func perform(_ items: [CleanItem], report: Reporter) async -> CleanReport {
        var r = CleanReport()
        var adminCmds: [String] = []
        var adminItems: [CleanItem] = []
        for (i, it) in items.enumerated() {
            if it.readOnly { continue }
            if let u = it.url, it.mode == .admin || it.mode == .adminEmpty || it.mode == .adminTrash, let why = Ignore.removalBlocker(u) {
                r.errors.append("\(it.title) : \(why)"); continue
            }
            report.tick("Nettoyage \(i + 1)/\(items.count) : \(it.title)")
            switch it.mode {
            case .delete:
                guard let u = it.url else { continue }
                do { try FS.remove(u); r.freed += it.size; r.count += 1 }
                catch { r.errors.append("\(it.title) : \(error.localizedDescription)") }
            case .emptyDir:
                guard let u = it.url else { continue }
                let res = FS.emptyDirectory(u)
                r.freed += res.freed; r.count += 1
                if res.errors > 0 { r.errors.append("\(it.title) : \(res.errors) fichier(s) en cours d'utilisation, laissés en place") }
                for p in res.protected { r.errors.append("\(it.title) › \(p), laissé en place") }
            case .trash:
                guard let u = it.url else { continue }
                do { try FS.trash(u); r.freed += it.size; r.count += 1 }
                catch { r.errors.append("\(it.title) : \(error.localizedDescription)") }
            case .admin:
                guard let u = it.url else { continue }
                adminCmds.append("rm -rf -- \(Shell.q(u.path))"); adminItems.append(it)
            case .adminEmpty:
                guard let u = it.url else { continue }
                adminCmds.append("find \(Shell.q(u.path)) -mindepth 1 -maxdepth 1 -exec rm -rf {} +"); adminItems.append(it)
            case .adminTrash:
                guard let u = it.url else { continue }
                adminCmds.append(([Services.bootoutCommand(plist: u)].compactMap { $0 } + [FS.adminTrashCommand(u)]).joined(separator: " ; ")); adminItems.append(it)
            case .custom:
                let res = await CustomActions.run(it)
                if res.ok { r.freed += res.freed; r.count += 1 }
                if let e = res.error { r.errors.append("\(it.title) : \(e)") }
            case .none:
                break
            }
        }
        if !adminCmds.isEmpty {
            report("Autorisation administrateur…")
            let res = Shell.admin(adminCmds.joined(separator: " ; ") + " ; true")
            if res.ok {
                r.freed += adminItems.reduce(0) { $0 + $1.size }
                r.count += adminItems.count
            } else {
                r.errors.append("Éléments système non supprimés (mot de passe refusé ou annulé).")
            }
        }
        return r
    }
}

// MARK: - Scan session (scan → review → clean)

@MainActor
final class ScanSession: ObservableObject, Identifiable {
    enum Phase { case idle, scanning, results, working, done }

    let key: String
    let title: String
    let scanner: Scanner
    var primaryTitle = "Nettoyer"
    var secondary: (title: String, mode: RemovalMode)? = nil
    /// More buttons next to the secondary one; `confirm` asks before running.
    var extraActions: [(title: String, mode: RemovalMode, confirm: String?)] = []
    var primaryMode: RemovalMode? = nil
    var emptyMessage = "Aucun élément trouvé"

    @Published var phase: Phase = .idle
    @Published var groups: [CleanGroup] = []
    @Published var selected: Set<UUID> = []
    @Published var status = ""
    @Published var report = CleanReport()
    @Published var focusedGroup: String?
    @Published var lastScan: Date?
    @Published var search = ""

    init(key: String, title: String, scanner: @escaping Scanner) {
        self.key = key
        self.title = title
        self.scanner = scanner
    }

    var reporter: Reporter { Reporter { [weak self] s in Task { @MainActor in self?.status = s } } }

    func scan() {
        phase = .scanning
        status = "Analyse en cours…"
        groups = []
        selected = []
        let rep = reporter
        let scanner = self.scanner
        Task {
            let g = await Task.detached(priority: .userInitiated) { await scanner(rep) }.value
            self.load(g)
        }
    }

    func load(_ g: [CleanGroup]) {
        groups = g.filter { !$0.items.isEmpty }.map { $0.protected() }
        selected = Set(groups.filter { !$0.infoOnly }.flatMap { $0.items.filter { $0.preselected && $0.actionable }.map(\.id) })
        if focusedGroup == nil || !groups.contains(where: { $0.id == focusedGroup }) { focusedGroup = groups.first?.id }
        phase = .results
        lastScan = Date()
    }

    var allItems: [CleanItem] { groups.flatMap(\.items) }
    var selectedItems: [CleanItem] { groups.flatMap { g in g.items.filter { selected.contains($0.id) } } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { groups.filter { !$0.infoOnly }.reduce(0) { $0 + $1.size } }

    func groupSize(_ g: CleanGroup) -> Int64 { g.items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func isSelected(_ i: CleanItem) -> Bool { selected.contains(i.id) }

    func toggle(_ i: CleanItem) {
        guard i.actionable else { return }
        if selected.contains(i.id) { selected.remove(i.id) } else { selected.insert(i.id) }
    }

    /// true = all, false = none, nil = some.
    func groupState(_ g: CleanGroup) -> Bool? {
        let ids = g.items.filter(\.actionable).map(\.id)
        let n = ids.filter { selected.contains($0) }.count
        if n == 0 { return false }
        return n == ids.count ? true : nil
    }

    func toggleGroup(_ g: CleanGroup) {
        let ids = g.items.filter(\.actionable).map(\.id)
        if groupState(g) == true { ids.forEach { selected.remove($0) } } else { ids.forEach { selected.insert($0) } }
    }

    func selectAll(_ on: Bool) {
        if on {
            selected = Set(groups.filter { !$0.infoOnly }.flatMap { $0.items.filter(\.actionable).map(\.id) })
        } else { selected = [] }
    }

    /// Ce qui sera réellement traité : cases cochées, jamais toutes les copies d'un doublon, mode imposé par le bouton, puis la règle 1.0
    /// de chaque groupe (rien de définitif hors groupe régénérable).
    func itemsToRun(mode override: RemovalMode? = nil) -> [CleanItem] {
        var items: [CleanItem] = []
        for g in groups where !g.infoOnly {
            var sel = g.items.filter { selected.contains($0.id) && $0.actionable }
            // Never remove every copy of a duplicate set.
            if g.keepOne, sel.count == g.items.count, !sel.isEmpty { sel.removeFirst() }
            if let m = override ?? primaryMode { sel = sel.map { var i = $0; if i.mode != .none { i.mode = m }; return i } }
            items += sel.map { CleanGroup.policy($0, regenerable: g.regenerable) }.filter { $0.mode != .none }
        }
        return items
    }

    func run(mode override: RemovalMode? = nil) {
        let items = itemsToRun(mode: override)
        guard !items.isEmpty else { return }
        phase = .working
        status = "Préparation…"
        let rep = reporter
        let title = self.title
        Task {
            let r = await Task.detached(priority: .userInitiated) { await Cleaner.perform(items, report: rep) }.value
            self.report = r
            self.phase = .done
            let removed = Set(items.map(\.id))
            self.groups = self.groups.map { g in var g = g; g.items.removeAll { removed.contains($0.id) }; return g }.filter { !$0.items.isEmpty }
            self.selected.subtract(removed)
            ActivityStore.shared.log(module: title,
                                     text: "\(Fmt.count(r.count, "élément traité", "éléments traités"))",
                                     bytes: r.freed)
        }
    }

    func backToResults() { phase = groups.isEmpty ? .idle : .results }
    func reset() { phase = .idle; groups = []; selected = [] }
}

/// Keeps scan results alive while the user moves between modules.
@MainActor
final class Sessions {
    static let shared = Sessions()
    private var store: [String: ScanSession] = [:]

    /// Fenêtre fermée : les listes de résultats (parfois des milliers d'éléments) sont rendues ; une analyse en cours ou un nettoyage continue.
    func releaseResults() {
        for s in store.values where s.phase == .results || s.phase == .done { s.reset() }
    }

    func get(_ key: String, title: String, configure: ((ScanSession) -> Void)? = nil, scanner: @escaping Scanner) -> ScanSession {
        if let s = store[key] { return s }
        let s = ScanSession(key: key, title: title, scanner: scanner)
        configure?(s)
        store[key] = s
        return s
    }
}

/// Ce qu'une action va faire, montré avant toute action : nombre et taille par façon de supprimer, puis les éléments.
enum CleanPlan {
    static func summary(_ items: [CleanItem]) -> String {
        func line(_ label: String, _ list: [CleanItem]) -> String? {
            list.isEmpty ? nil : "\(label) : \(Fmt.count(list.count, "élément")), \(Fmt.bytes(list.reduce(0) { $0 + $1.size }))"
        }
        let trash = items.filter { $0.mode == .trash || $0.mode == .adminTrash }
        let gone = items.filter { CleanGroup.isDefinitive($0.mode) }
        let evict = items.filter { $0.mode == .custom("evict") }
        var out = [line("À la Corbeille (récupérable)", trash),
                   line("Supprimés définitivement (caches et fichiers recréés seuls)", gone),
                   line("Retirés du Mac, gardés dans le cloud", evict)].compactMap { $0 }
        if items.contains(where: { $0.mode == .admin || $0.mode == .adminEmpty || $0.mode == .adminTrash }) { out.append("Mot de passe administrateur demandé pour les éléments système.") }
        let names = items.sorted { $0.size > $1.size }.prefix(8).map { "· \($0.title) — \(Fmt.bytes($0.size))" }
        out.append(""); out += names
        if items.count > 8 { out.append("… et \(items.count - 8) autre(s)") }
        return out.joined(separator: "\n")
    }
}
