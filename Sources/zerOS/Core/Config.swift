import Foundation
import AppKit

/// Configuration enregistrée sur ce Mac (UserDefaults, clé « config ») : aucun disque, dossier ni matériel n'est connu d'avance.
/// Les disques sont repérés par l'UUID de leur volume (le nom ne sert qu'à l'affichage) : renommer un disque ne casse rien, et deux
/// disques de même nom ne se confondent pas.

/// Un volume monté, tel que macOS le décrit.
struct VolumeInfo: Equatable, Sendable {
    let mount: URL
    let uuid: String?
    let name: String
}

enum Volumes {
    /// Volumes locaux montés (getfsstat : aucun accès réseau, jamais bloquant). Les volumes système cachés sont ignorés, sauf le disque de
    /// démarrage et son volume de données.
    nonisolated static func mounted() -> [VolumeInfo] {
        let n = getfsstat(nil, 0, MNT_NOWAIT)
        guard n > 0 else { return [] }
        var blank = statfs()
        memset(&blank, 0, MemoryLayout<statfs>.size)
        var buf = Array(repeating: blank, count: Int(n))
        let got = getfsstat(&buf, Int32(buf.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard got > 0 else { return [] }
        var out: [VolumeInfo] = []
        for var s in buf.prefix(Int(got)) {
            guard s.f_flags & UInt32(MNT_LOCAL) != 0 else { continue }
            let from = withUnsafeBytes(of: &s.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let on = withUnsafeBytes(of: &s.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard from.hasPrefix("/dev/") else { continue }
            if on.hasPrefix("/System/Volumes/"), on != "/System/Volumes/Data" { continue }
            if on.hasPrefix("/Library/Developer/") { continue }
            let url = URL(fileURLWithPath: on)
            let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeNameKey]
            let rv = try? url.resourceValues(forKeys: keys)
            out.append(VolumeInfo(mount: url, uuid: rv?.volumeUUIDString, name: rv?.volumeName ?? url.lastPathComponent))
        }
        return out
    }

    /// Chemin réel (liens symboliques résolus, « /private/var » comprise : `resolvingSymlinksInPath` la raccourcit en « /var »).
    nonisolated static func realURL(_ url: URL) -> URL {
        let u = url.standardizedFileURL
        if let c = try? u.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath { return URL(fileURLWithPath: c) }
        return u
    }

    /// Le volume qui contient ce chemin (le plus profond des points de montage).
    nonisolated static func containing(_ url: URL, in vols: [VolumeInfo] = mounted()) -> VolumeInfo? {
        let p = realURL(url).path
        return vols.filter { v in
            let m = v.mount.path
            return p == m || p.hasPrefix(m == "/" ? "/" : m + "/")
        }.max { $0.mount.path.count < $1.mount.path.count }
    }
}

/// Référence stable à un volume : l'UUID (nil seulement pour un réglage ancien, appris dès que le disque est vu), et le nom affiché.
struct VolumeRef: Codable, Equatable, Sendable {
    var uuid: String?
    var name: String
}

/// Un disque entier (`path` vide) ou un dossier sur un disque (`path` relatif à la racine du volume).
struct Location: Codable, Equatable, Sendable {
    var volume: VolumeRef
    var path: String

    var isRoot: Bool { path.isEmpty }
    /// Nom du dossier, ou du disque si c'est sa racine.
    var title: String { isRoot ? volume.name : (path as NSString).lastPathComponent }

    nonisolated static func make(for url: URL, in vols: [VolumeInfo] = Volumes.mounted()) -> Location? {
        let u = Volumes.realURL(url)
        guard let v = Volumes.containing(u, in: vols) else { return nil }
        let m = v.mount.path, p = u.path
        let rel = p == m ? "" : String(p.dropFirst(m == "/" ? 1 : m.count + 1))
        return Location(volume: VolumeRef(uuid: v.uuid, name: v.name), path: rel)
    }

    /// Le volume correspondant parmi les volumes montés : par UUID, sinon (réglage ancien sans UUID) par nom.
    nonisolated func volumeInfo(in vols: [VolumeInfo]) -> VolumeInfo? {
        if let id = volume.uuid { return vols.first { $0.uuid == id } }
        return vols.first { $0.name == volume.name }
    }

    nonisolated func resolve(in vols: [VolumeInfo] = Volumes.mounted()) -> URL? {
        guard let v = volumeInfo(in: vols) else { return nil }
        return isRoot ? v.mount : v.mount.appendingPathComponent(path)
    }

    /// « Disque externe » (disque entier) ou « Documents (sur Macintosh HD) » : le nom du disque est celui d'aujourd'hui s'il est branché.
    func label(in vols: [VolumeInfo] = Volumes.mounted()) -> String {
        let disk = volumeInfo(in: vols)?.name ?? volume.name
        return isRoot ? disk : "\(title) (sur \(disk))"
    }
}

struct AppConfig: Codable, Equatable, Sendable {
    /// 2 : disque de données choisi à part (1.0) ; 1 : il se déduisait du réglage « source » (repris une fois, `Config.bootstrap`).
    var version = 2
    /// Disque de données : disque externe vers lequel « Déplacer » propose de ranger les données lourdes d'apps. En lecture seule pour le
    /// nettoyage (rien n'y est jamais supprimé). nil = aucun.
    var dataDisk: Location?
}

enum Config {
    static let key = "config"

    // MARK: Lecture / écriture

    static var current: AppConfig? {
        get {
            guard let d = Prefs.store.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(AppConfig.self, from: d)
        }
        set {
            if let newValue, let d = try? JSONEncoder().encode(newValue) { Prefs.store.set(keepingOthers(d), forKey: key) } else { Prefs.store.removeObject(forKey: key) }
            invalidate()
        }
    }

    /// Réglages enregistrés que cette version ne connaît pas (ceux d'une autre version de zerOS) : recopiés tels
    /// quels à chaque écriture, jamais effacés ni modifiés.
    static func keepingOthers(_ d: Data) -> Data {
        guard let old = Prefs.store.data(forKey: key), let before = (try? JSONSerialization.jsonObject(with: old)) as? [String: Any],
              var after = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return d }
        let known = Set(Mirror(reflecting: AppConfig()).children.compactMap(\.label))
        for (k, v) in before where !known.contains(k) && after[k] == nil { after[k] = v }
        return (try? JSONSerialization.data(withJSONObject: after, options: [.sortedKeys])) ?? d
    }

    /// Valeur brute d'un réglage enregistré (même inconnu de cette version).
    static func stored(_ k: String) -> Any? {
        guard let d = Prefs.store.data(forKey: key), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return o[k]
    }

    /// Au lancement : reprend les réglages d'une version précédente si ce Mac en avait, puis met à jour les noms de disques.
    static func bootstrap() {
        adoptDataDisk()
        invalidate(); sync()
    }

    /// Configuration d'avant la 1.0 (version 1) : le disque de données se déduisait du réglage « source » quand c'était un disque externe
    /// entier. Repris une seule fois (version 2 ensuite : un disque retiré dans Réglages ne revient pas). Rien d'autre n'est modifié.
    static func adoptDataDisk() {
        guard var c = current, c.version < 2 else { return }
        if c.dataDisk == nil, let raw = stored("source"), let d = try? JSONSerialization.data(withJSONObject: raw),
           let loc = try? JSONDecoder().decode(Location.self, from: d), loc.isRoot { c.dataDisk = loc }
        c.version = 2
        current = c
    }

    /// Aucune configuration : l'assistant de premier lancement doit s'afficher.
    static var needsWizard: Bool { current == nil }


    // MARK: Résolution (avec un cache court : `Ignore.readOnly` est appelé des milliers de fois par analyse)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (at: Date, paths: [String])?

    static func invalidate() {
        lock.withLock { cache = nil }
    }

    static func resolved(_ loc: Location?, in vols: [VolumeInfo] = Volumes.mounted()) -> URL? { loc?.resolve(in: vols) }

    /// Disque de données s'il est branché : toujours en lecture seule pour le reste de zerOS.
    static var protectedPaths: [String] {
        if let c = lock.withLock({ cache }), Date().timeIntervalSince(c.at) < 10 { return c.paths }
        let vols = Volumes.mounted()
        let cfg = current
        // Chemin réel et chemin standardisé (qui diffèrent sous /private) : les deux écritures sont protégées.
        var paths: [String] = []
        var locs = [cfg?.dataDisk].compactMap { $0 }
        for u in locs.compactMap({ $0.resolve(in: vols) }) {
            for p in [Volumes.realURL(u).path, u.standardizedFileURL.path] where !paths.contains(p) { paths.append(p) }
        }
        lock.withLock { cache = (Date(), paths) }
        return paths
    }

    /// Disque de données branché (disque externe) : c'est là que « Déplacer » propose de ranger les données d'apps.
    static var relocateTarget: (name: String, url: URL)? {
        guard let s = current?.dataDisk else { return nil }
        let vols = Volumes.mounted()
        guard let v = s.volumeInfo(in: vols), v.mount.path.hasPrefix("/Volumes/") else { return nil }
        return (v.name, v.mount)
    }

    /// Ce volume monté est-il le disque de données ?
    static func isDataDisk(_ v: VolumeInfo) -> Bool { matches(current?.dataDisk, v) }
    private static func matches(_ l: Location?, _ v: VolumeInfo) -> Bool {
        guard let l else { return false }
        if let id = l.volume.uuid { return v.uuid == id }
        return v.name == l.volume.name
    }

    /// Choix d'un disque de données : un disque externe entier (un dossier choisi désigne son disque). Refus expliqué sinon.
    static func dataDiskChoice(_ url: URL, in vols: [VolumeInfo] = Volumes.mounted()) -> Result<Location, DataDiskRefusal> {
        guard let v = Volumes.containing(url, in: vols) else { return .failure(.unreadable) }
        guard v.mount.path.hasPrefix("/Volumes/") else { return .failure(.notExternal) }
        return .success(Location(volume: VolumeRef(uuid: v.uuid, name: v.name), path: ""))
    }

    enum DataDiskRefusal: Error { case notExternal, unreadable
        var text: String {
            switch self {
            case .notExternal: "Choisissez un disque externe : le disque interne ne peut pas être le disque de données."
            case .unreadable: "Ce disque n'est pas lisible."
            }
        }
    }


    /// Met à jour les noms affichés et apprend l'UUID des réglages anciens dès que le disque est branché. À appeler au lancement et à chaque montage.
    static func sync() {
        guard var c = current else { return }
        let vols = Volumes.mounted()
        var changed = false
        func fix(_ l: inout Location?) {
            guard var loc = l, let v = loc.volumeInfo(in: vols) else { return }
            if loc.volume.uuid == nil, v.uuid != nil { loc.volume.uuid = v.uuid; changed = true }
            if loc.volume.name != v.name { loc.volume.name = v.name; changed = true }
            l = loc
        }
        fix(&c.dataDisk)
        if changed { current = c }
    }
}

/// Fenêtre de choix d'un disque ou d'un dossier.
enum FolderPicker {
    /// nil si l'utilisateur annule.
    @MainActor static func pick(_ message: String, prompt: String = "Choisir", start: URL? = nil) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.canCreateDirectories = true
        p.message = message
        p.prompt = prompt
        p.directoryURL = start ?? URL(fileURLWithPath: "/Volumes")
        return p.runModal() == .OK ? p.url : nil
    }
}

