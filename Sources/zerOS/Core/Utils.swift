import Foundation
import AppKit

// MARK: - Formatting

enum Fmt {
    static let fr = Locale(identifier: "fr_FR")

    static func bytes(_ b: Int64) -> String {
        guard b > 0 else { return "0 o" }
        return ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    /// Memory (RAM, swap, process footprints): binary units (1 Go = 1 024³ o), like Activity Monitor.
    /// Disk sizes stay decimal (`bytes`), like Finder.
    static func mem(_ b: Int64) -> String {
        guard b > 0 else { return "0 o" }
        let units = ["o", "Ko", "Mo", "Go", "To"]
        var v = Double(b), i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return "\(number(v, max: (i >= 3 && v < 100) ? 2 : (v < 10 && i > 0 ? 1 : 0))) \(units[i])"
    }

    /// Le seul formateur de nombres de l'app : format français (« 1 234,5 »). `digits` chiffres après la virgule, ou au plus `max`.
    static func number(_ v: Double, digits: Int? = nil, max: Int = 0) -> String {
        let p: NumberFormatStyleConfiguration.Precision = digits.map { .fractionLength($0) } ?? .fractionLength(0...max)
        return v.formatted(.number.precision(p).locale(fr))
    }

    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(fr))
    }

    static func dateTime(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(fr))
    }

    static func ago(_ d: Date?) -> String {
        guard let d else { return "jamais" }
        if abs(d.timeIntervalSinceNow) < 60 { return "à l'instant" }
        return relative.localizedString(for: d, relativeTo: Date())
    }
    /// Créé une fois (en créer un par ligne de liste coûtait à chaque affichage).
    nonisolated(unsafe) private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.locale = fr; f.unitsStyle = .full; return f
    }()

    static func uptime(_ s: TimeInterval) -> String {
        let t = Int(s)
        let d = t / 86400, h = (t % 86400) / 3600, m = (t % 3600) / 60
        return d > 0 ? "\(d) j \(h) h" : "\(h) h \(m) min"
    }

    /// « 1 h 51 min », « 12 min 05 s », « 42 s ».
    static func duration(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        let m = (t % 3600) / 60, sec = t % 60
        // Au-dessus d'une heure, à la minute près (1 h 50 min 59 s → 1 h 51 min).
        if t >= 3600 { let mins = (t + 30) / 60; return "\(mins / 60) h \(String(format: "%02d", mins % 60)) min" }
        if m > 0 { return "\(m) min \(String(format: "%02d", sec)) s" }
        return "\(sec) s"
    }

    /// « 42 % », « 100,0 % » (espace insécable).
    static func percent(_ v: Double, digits: Int = 0) -> String { number(v, digits: digits) + "\u{00A0}%" }

    static func speed(_ bytesPerSec: Double) -> String {
        bytesPerSec < 1 ? "0 o/s" : bytes(Int64(bytesPerSec)) + "/s"
    }

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) " + (n > 1 ? (plural ?? singular + "s") : singular)
    }
}

// MARK: - File system

enum FS {
    static let fm = FileManager.default
    static let home = URL(fileURLWithPath: NSHomeDirectory())

    static func lib(_ p: String) -> URL { home.appendingPathComponent("Library").appendingPathComponent(p) }
    static func h(_ p: String) -> URL { home.appendingPathComponent(p) }
    /// zerOS's own data folder (history, self-test output).
    static var support: URL { lib("Application Support/zerOS") }

    static func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }

    static func isDir(_ u: URL) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
    }

    static func isSymlink(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    static func children(_ u: URL, hidden: Bool = false) -> [URL] {
        (try? fm.contentsOfDirectory(at: u,
                                     includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .contentModificationDateKey],
                                     options: hidden ? [] : [.skipsHiddenFiles])) ?? []
    }

    static let sizeKeys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]

    /// Space actually used on disk (recursive for folders).
    static func allocatedSize(_ u: URL) -> Int64 {
        guard let v = try? u.resourceValues(forKeys: Set(sizeKeys)) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        var total: Int64 = 0
        if let e = fm.enumerator(at: u, includingPropertiesForKeys: sizeKeys, options: [], errorHandler: { _, _ in true }) {
            for case let f as URL in e {
                if let r = try? f.resourceValues(forKeys: Set(sizeKeys)), r.isDirectory != true, r.isSymbolicLink != true {
                    total += Int64(r.totalFileAllocatedSize ?? r.fileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }

    static func plist(_ u: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: u) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func bundleInfo(_ app: URL) -> [String: Any]? { plist(app.appendingPathComponent("Contents/Info.plist")) }

    static func appURL(forBundleID id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    static func appName(forBundleID id: String) -> String? {
        guard let u = appURL(forBundleID: id) else { return nil }
        return u.deletingPathExtension().lastPathComponent
    }

    static func displayName(_ u: URL) -> String {
        u.pathExtension == "app" ? u.deletingPathExtension().lastPathComponent : u.lastPathComponent
    }

    struct ProtectedError: LocalizedError {
        var reason = "dossier protégé (lecture seule)"
        var errorDescription: String? { "\(reason), rien n'a été supprimé" }
    }

    /// Every removal goes through here: blocked and read-only paths, and folders holding a protected item, are refused.
    static func remove(_ u: URL) throws {
        if let r = Ignore.removalBlocker(u) { throw ProtectedError(reason: r) }
        try fm.removeItem(at: u)
    }
    static func trash(_ u: URL) throws {
        if let r = Ignore.removalBlocker(u) { throw ProtectedError(reason: r) }
        var out: NSURL?
        try fm.trashItem(at: u, resultingItemURL: &out)
        TrashLog.record(out as URL?)
    }

    /// Commande (lancée avec le mot de passe administrateur) qui met un élément système à la Corbeille de l'utilisateur au lieu de le
    /// supprimer : récupérable, jamais écrasé (`mv -n`, nom libre choisi d'avance). Le chemin d'arrivée est noté (`TrashLog`).
    static func adminTrashCommand(_ u: URL) -> String {
        let dest = freeTrashName(for: u)
        TrashLog.record(dest)
        return "mv -n -- \(Shell.q(u.path)) \(Shell.q(dest.path))"
    }

    /// Nom libre dans la Corbeille de l'utilisateur (« nom 2026-11-09 10.30.12.ext » si le nom est pris).
    nonisolated(unsafe) private static var reserved: Set<String> = []
    private static let reserveLock = NSLock()

    static func freeTrashName(for u: URL) -> URL {
        reserveLock.withLock {
            let c = pickTrashName(for: u)
            reserved.insert(c.path)
            return c
        }
    }

    private static func pickTrashName(for u: URL) -> URL {
        let trash = h(".Trash")
        func taken(_ c: URL) -> Bool { exists(c) || reserved.contains(c.path) }
        let plain = trash.appendingPathComponent(u.lastPathComponent)
        guard taken(plain) else { return plain }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let ext = u.pathExtension, base = u.deletingPathExtension().lastPathComponent
        var n = 0
        while true {
            let name = base + " " + f.string(from: Date()) + (n == 0 ? "" : " \(n)") + (ext.isEmpty ? "" : "." + ext)
            let c = trash.appendingPathComponent(name)
            if !taken(c) { return c }
            n += 1
        }
    }

    struct EmptyResult: Sendable { var freed: Int64 = 0; var removed = 0; var errors = 0; var protected: [String] = [] }

    /// Vide un dossier en le gardant. Chaque élément contenu passe par `Ignore.removalBlocker` (un projet, un dossier en lecture seule ou
    /// bloqué, un dossier cloud non téléchargé n'est jamais supprimé, même rangé dans un dossier de cache) ; refusés et erreurs sont comptés.
    static func emptyDirectory(_ u: URL) -> EmptyResult {
        var r = EmptyResult()
        if let why = Ignore.removalBlocker(u) { r.errors = 1; r.protected.append("\(u.lastPathComponent) : \(why)"); return r }
        for c in children(u, hidden: true) {
            if let why = Ignore.removalBlocker(c) { r.protected.append("\(c.lastPathComponent) : \(why)"); continue }
            let s = allocatedSize(c)
            do { try fm.removeItem(at: c); r.freed += s; r.removed += 1 } catch { r.errors += 1 }
        }
        return r
    }

    static func reveal(_ u: URL) { NSWorkspace.shared.activateFileViewerSelecting([u]) }

    /// Walks a folder tree. `body` returns false to stop.
    static func walk(_ root: URL, keys: [URLResourceKey], skipHidden: Bool = true, skipPackages: Bool = true,
                     exclude: (URL) -> Bool = { _ in false }, body: (URL, URLResourceValues) -> Bool) {
        var opts: FileManager.DirectoryEnumerationOptions = []
        if skipHidden { opts.insert(.skipsHiddenFiles) }
        if skipPackages { opts.insert(.skipsPackageDescendants) }
        let allKeys = Array(Set(keys + [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]))
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: allKeys, options: opts, errorHandler: { _, _ in true }) else { return }
        for case let f as URL in e {
            if exclude(f) { e.skipDescendants(); continue }
            guard let v = try? f.resourceValues(forKeys: Set(allKeys)) else { continue }
            if !body(f, v) { return }
        }
    }

    /// Lists a folder on a side thread and gives up after `timeout` (frozen cloud or network folders can block for minutes).
    static func responds(_ u: URL, timeout: TimeInterval = 4) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = try? FileManager.default.contentsOfDirectory(atPath: u.path)
            sem.signal()
        }
        return sem.wait(timeout: .now() + timeout) == .success
    }

    static var volumeFree: Int64 {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(v?.volumeAvailableCapacity ?? 0)
    }

    static func newest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (x?, y?): return max(x, y)
        default: return a ?? b
        }
    }
}

// MARK: - Shell

enum Shell {
    struct Result {
        let status: Int32
        let out: String
        let err: String
        /// Le délai est passé : le processus a été arrêté (ou abandonné s'il ne s'arrêtait pas) ; `out` est ce qui avait été lu.
        var timedOut = false
        var ok: Bool { status == 0 && !timedOut }
    }

    /// Lance un programme et rend sa sortie. Les deux tubes sont lus en même temps que le programme tourne (une sortie de plus de 64 Ko
    /// ne bloque pas). Le délai est une vraie limite : après `timeout`, arrêt (SIGTERM), puis arrêt forcé (SIGKILL) une seconde plus tard,
    /// et la main est rendue au plus ≈ 2,5 s après le délai même si le programme ne meurt pas (bloqué dans le noyau sur un disque) ou si un
    /// processus lancé par lui garde les tubes ouverts : jamais d'attente sans fin.
    @discardableResult
    static func run(_ path: String, _ args: [String] = [], timeout: TimeInterval = 120) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return Result(status: -1, out: "", err: error.localizedDescription) }
        let box = Output()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { box.out = o.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { box.err = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let deadline = DispatchTime.now() + timeout
        let finished = g.wait(timeout: deadline) == .success && exited.wait(timeout: deadline) == .success
        if !finished {
            p.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            _ = g.wait(timeout: .now() + 0.5)
        }
        return Result(status: finished ? p.terminationStatus : -2,
                      out: String(decoding: box.out, as: UTF8.self),
                      err: String(decoding: box.err, as: UTF8.self) + (finished ? "" : "\n(délai de \(Int(timeout)) s dépassé)"),
                      timedOut: !finished)
    }

    /// Sortie lue par les fils de lecture (qui peuvent encore écrire après un délai dépassé).
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var o = Data(), e = Data()
        var out: Data { get { lock.lock(); defer { lock.unlock() }; return o } set { lock.lock(); o = newValue; lock.unlock() } }
        var err: Data { get { lock.lock(); defer { lock.unlock() }; return e } set { lock.lock(); e = newValue; lock.unlock() } }
    }

    @discardableResult
    static func sh(_ cmd: String, timeout: TimeInterval = 120) -> Result { run("/bin/sh", ["-c", cmd], timeout: timeout) }

    @discardableResult
    static func osa(_ src: String) -> Result { run("/usr/bin/osascript", ["-e", src]) }

    @discardableResult
    static func jxa(_ src: String) -> Result { run("/usr/bin/osascript", ["-l", "JavaScript", "-e", src]) }

    /// Runs a shell command as administrator (macOS asks for the password).
    @discardableResult
    static func admin(_ cmd: String, timeout: TimeInterval = 600) -> Result {
        let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src = "do shell script \"\(esc)\" with prompt \"zerOS a besoin de votre mot de passe pour continuer.\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", src], timeout: timeout)
    }

    /// Single-quotes a string for the shell.
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Permissions

enum Perms {
    static var fullDiskAccess: Bool {
        if (try? FileManager.default.contentsOfDirectory(atPath: FS.lib("Safari").path)) != nil { return true }
        if let fh = FileHandle(forReadingAtPath: FS.lib("Application Support/com.apple.TCC/TCC.db").path) {
            try? fh.close()
            return true
        }
        return false
    }

    /// Accès complet au disque pour l'interface : lu hors du fil principal, relu chaque fois que zerOS redevient l'app active (accès
    /// accordé ou retiré dans Réglages Système pendant que zerOS tourne : la bannière disparaît ou revient sans relancer).
    @MainActor @Observable final class Access {
        static let shared = Access()
        private(set) var fullDisk = true
        private init() {
            refresh()
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Access.shared.refresh() }
            }
        }
        func refresh() {
            Task {
                let v = await Task.detached(priority: .userInitiated) { Perms.fullDiskAccess }.value
                if v != fullDisk { fullDisk = v }
            }
        }
    }

    static func open(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(u) }
    }

    static func openFullDiskAccess() { open("Privacy_AllFiles") }

    static func openLoginItems() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(u) }
    }
}

// MARK: - Settings

/// Réglages modifiables. Aucune valeur personnelle par défaut : un Mac neuf démarre vide (assistant de premier lancement),
/// un Mac déjà réglé est repris une fois par `Legacy.migrate`.
enum Prefs {
    /// Là où les réglages sont lus et écrits (l'autotest le remplace par un jeu de réglages temporaire).
    nonisolated(unsafe) static var store: UserDefaults = .standard { didSet { Config.invalidate() } }

    /// Dossiers de compilation de projets de développement : jamais proposés au nettoyage (Réglages > Protection).
    static var ignoredDevCaches: [String] {
        get { store.stringArray(forKey: "ignoredDevCaches") ?? [] }
        set { store.set(newValue, forKey: "ignoredDevCaches") }
    }
    static let defaultProjectExtensions = ["logicx", "band", "als", "aep", "aepx", "prproj", "toe", "psd", "psb",
                                           "fcpbundle", "photoslibrary", "photolibrary"]
    /// File and package extensions of projects, read-only wherever they are (Réglages > Protection).
    static var projectExtensions: [String] {
        get { store.stringArray(forKey: "projectExtensions") ?? defaultProjectExtensions }
        set { store.set(newValue.map { $0.lowercased() }, forKey: "projectExtensions") }
    }
}

// MARK: - Protected paths

/// Two protection levels:
/// - **blocked** (`hard` + user exclusions): never read, never shown, never removed.
/// - **read-only** (`readOnlyPaths` + music/video projects): analysed and shown, never preselected, never removable.
enum Ignore {
    static var userPaths: [String] { Prefs.store.stringArray(forKey: "ignoredPaths") ?? [] }

    /// Never touched, whatever the module.
    static var hard: [String] {
        [FS.h(".claude").path, FS.lib("Keychains").path, FS.h(".ssh").path, "/System", "/usr", "/bin", "/sbin"]
    }

    static func blocked(_ u: URL) -> Bool {
        let p = u.standardizedFileURL.path
        return (hard + userPaths).contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    /// Toujours en lecture seule : les disques et dossiers de la configuration (`Config.protectedPaths`), s'ils sont branchés.
    static var readOnlyDefaults: [String] { Config.protectedPaths }

    static var readOnlyUserPaths: [String] {
        get { Prefs.store.stringArray(forKey: "readOnlyPaths") ?? [] }
        set { Prefs.store.set(newValue, forKey: "readOnlyPaths") }
    }

    static var readOnlyPaths: [String] { readOnlyDefaults + readOnlyUserPaths }

    static func isTrash(_ p: String) -> Bool {
        p.contains("/.Trashes/") || p.hasSuffix("/.Trashes") || p.contains("/.Trash/") || p.hasSuffix("/.Trash")
    }

    /// The item itself is a project (by extension, or an Ableton "… Project" folder). Name checks plus one `exists` at most.
    static func isProject(_ u: URL) -> Bool {
        if Prefs.projectExtensions.contains(u.pathExtension.lowercased()) { return true }
        return u.lastPathComponent.hasSuffix(" Project") && FS.exists(u.appendingPathComponent("Ableton Project Info"))
    }

    /// Analysis only. Trash folders stay emptyable (their content was already thrown away);
    /// project files and packages (`Prefs.projectExtensions`, Ableton "… Project" folders) are read-only wherever they live.
    static func readOnly(_ u: URL) -> Bool {
        let p = u.standardizedFileURL.path
        if isTrash(p) { return false }
        if readOnlyPaths.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { return true }
        var dir = URL(fileURLWithPath: "/")
        for c in u.standardizedFileURL.pathComponents.dropFirst() {
            dir.appendPathComponent(c)
            if isProject(dir) { return true }
        }
        return false
    }

    /// Neither blocked nor read-only (path check only, cheap: used by the UI). See `removalBlocker` for folders.
    static func removable(_ u: URL) -> Bool { !blocked(u) && !readOnly(u) }

    /// Folders of regenerable data that cannot hold a project: no content check needed.
    static var regenerableRoots: [String] {
        [FS.lib("Caches").path, FS.lib("Logs").path, FS.lib("Developer/Xcode/DerivedData").path, "/Library/Caches", "/Library/Logs"]
    }

    enum ContentCheck: Equatable { case clean, protected(String), cloudOnly(String), unknown }

    /// Looks inside a folder for a protected item (project, read-only or blocked path), with a time and size budget.
    /// A never-downloaded cloud folder inside stops the check (it is not opened: that would download it). Runs on a side thread so a
    /// frozen cloud or network folder cannot block the caller: past the budget, the answer is `.unknown`.
    static func checkContents(_ dir: URL, budget: TimeInterval = 5, maxEntries: Int = 300_000) -> ContentCheck {
        let root = dir.standardizedFileURL.path
        let inside = (hard + userPaths + readOnlyPaths).first { $0.hasPrefix(root + "/") }
        if let inside { return .protected(inside.replacingOccurrences(of: FS.home.path, with: "~")) }
        final class Box: @unchecked Sendable { var result = ContentCheck.unknown }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let deadline = Date().addingTimeInterval(budget)
        Thread.detachNewThread {
            defer { sem.signal() }
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [],
                                                         errorHandler: { _, _ in true }) else { return }
            var n = 0
            for case let f as URL in e {
                n += 1
                if n % 500 == 0, Date() > deadline { return }
                if n > maxEntries { return }
                if isProject(f) { box.result = .protected(f.lastPathComponent); return }
                if CloudCleanup.isDatalessDir(f) { box.result = .cloudOnly(f.lastPathComponent); return }
            }
            box.result = .clean
        }
        return sem.wait(timeout: .now() + budget + 0.5) == .success ? box.result : .unknown
    }

    /// Why `u` must not be removed, or nil when it can be. Folders are checked inside (except Trash and caches).
    static func removalBlocker(_ u: URL) -> String? {
        if blocked(u) { return "élément bloqué" }
        if readOnly(u) { return "dossier protégé (lecture seule)" }
        let p = u.standardizedFileURL.path
        guard FS.isDir(u), !FS.isSymlink(u), !isTrash(p),
              !regenerableRoots.contains(where: { p.hasPrefix($0 + "/") }), !p.contains("/Data/Library/Caches/") else { return nil }
        // Removing a never-downloaded cloud folder deletes it from the cloud too (nothing of it is on the Mac).
        if CloudCleanup.isDatalessDir(u) { return "dossier cloud non téléchargé, le supprimer le retirerait du cloud" }
        switch checkContents(u) {
        case .clean: return nil
        case .protected(let what): return "contient un projet protégé (\(what))"
        case .cloudOnly(let what): return "contient un dossier cloud non téléchargé (\(what)), le supprimer le retirerait du cloud"
        case .unknown: return "contenu trop long à vérifier, gardé par prudence"
        }
    }

    static func addReadOnly(_ path: String) {
        if !readOnlyUserPaths.contains(path) { readOnlyUserPaths.append(path) }
    }

    static func removeReadOnly(_ path: String) { readOnlyUserPaths.removeAll { $0 == path } }

    static func add(_ path: String) {
        var a = userPaths
        if !a.contains(path) { a.append(path) }
        Prefs.store.set(a, forKey: "ignoredPaths")
    }

    static func remove(_ path: String) {
        Prefs.store.set(userPaths.filter { $0 != path }, forKey: "ignoredPaths")
    }
}

/// Éléments que zerOS a mis à la Corbeille (chemin d'arrivée, date) : « Vider la Corbeille » dit combien y sont depuis moins de 24 h.
enum TrashLog {
    struct Entry: Codable { let path: String; let at: Date }
    nonisolated(unsafe) static var file = FS.support.appendingPathComponent("mis-a-la-corbeille.json")
    private static let lock = NSLock()

    static func load() -> [Entry] { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? [] }

    static func record(_ u: URL?) {
        guard let u else { return }
        lock.withLock {
            let week = Date().addingTimeInterval(-7 * 86400)
            let list = load().filter { $0.at > week } + [Entry(path: u.path, at: Date())]
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(list).write(to: file, options: .atomic)
        }
    }

    /// Éléments mis à la Corbeille par zerOS depuis moins de 24 h et toujours dans `bin`.
    static func recent(in bin: URL, now: Date = Date()) -> Int {
        let root = bin.standardizedFileURL.path + "/"
        let day = now.addingTimeInterval(-86400)
        return Set(load().filter { $0.at > day && $0.path.hasPrefix(root) && FileManager.default.fileExists(atPath: $0.path) }.map(\.path)).count
    }
}
