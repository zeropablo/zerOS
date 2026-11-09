import Foundation

/// Arbre de tailles d'un disque (Stockage). Les petits éléments ne sont pas gardés : leurs octets restent dans `other`, de sorte que
/// la taille d'un dossier est toujours exacte et que `size − Σ enfants` = octets propres du dossier (fichiers directs + petits éléments).
final class SNode: @unchecked Sendable {
    let name: String
    var size: Int64
    var isDir: Bool
    var children: [SNode] = []
    weak var parent: SNode?
    /// Calculée à la demande par `Classifier` (jamais enregistrée : les règles évoluent).
    var cls: Classification?
    /// Dossier de regroupement : sans règle propre, mais un de ses descendants en a une (ex. /Users, ~/Library). Posé par `StorageAnalysis`.
    var structural = false

    init(name: String, size: Int64, isDir: Bool) { self.name = name; self.size = size; self.isDir = isDir }

    /// Chemin complet ; la racine porte son chemin absolu comme nom.
    var path: String {
        guard let p = parent else { return name }
        return p.path == "/" ? "/" + name : p.path + "/" + name
    }

    var own: Int64 { max(0, size - children.reduce(0) { $0 + $1.size }) }

    /// Descend par composants de chemin depuis cette racine.
    func find(_ absolute: String) -> SNode? {
        let root = name == "/" ? "" : name
        guard absolute == name || absolute.hasPrefix(root + "/") else { return nil }
        var node = self
        for comp in absolute.dropFirst(root.count).split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == comp }) else { return nil }
            node = next
        }
        return node
    }

    /// De `root` (ou du parent direct d'un enfant de `root` si `root` est virtuel) jusqu'à `self`.
    func chain(upTo root: SNode) -> [SNode] {
        var out = [self], cur = self
        while cur !== root {
            if root.children.contains(where: { $0 === cur }) { out.insert(root, at: 0); break }
            guard let p = cur.parent else { break }
            out.insert(p, at: 0); cur = p
        }
        return out
    }
}

enum StorageScan {
    static let rulesVersion = 1
    /// Jamais parcourus en plus des chemins bloqués (`Ignore`) : montages, autofs, swap, index.
    static let skip: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm", "/cores", "/home", "/net", "/Network",
                                    "/.Spotlight-V100", "/.fseventsd", "/.DocumentRevisions-V100", "/.vol"]

    struct Progress: Sendable { var entries: Int; var bytes: Int64; var current: String }
    struct Result: @unchecked Sendable {
        let root: SNode
        var partial: Bool
        var entries: Int
        var seconds: Double
        var unreadable: Int
        var skipped: [String]
        /// Le volume analysé a disparu (débranché) ou changé pendant l'analyse : le résultat est partiel et ne doit pas être gardé en cache.
        var volumeLost = false
    }

    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var cancelled: Bool { lock.withLock { flag } }
        func cancel() { lock.withLock { flag = true } }
    }

    /// Un enfant est gardé s'il pèse au moins ce seuil ET au moins 1/500 de son dossier (au plus `maxKids` par dossier).
    static let keepMin: Int64 = 512 * 1024
    static let maxKids = 40
    /// Un fichier devient un nœud à partir de cette taille (les autres ne comptent que dans leur dossier).
    static let fileNode: Int64 = 256 * 1024

    private final class Frame {
        let node: SNode
        var bytes: Int64 = 0
        var kids: [SNode] = []
        /// Dossier ignoré : fts le renvoie quand même en post-ordre (FTS_DP) juste après, il faut donc un cadre à dépiler.
        var skipped = false
        init(_ n: SNode) { node = n }
    }

    /// Parcours fts d'un seul fil (jamais sur le fil principal). Respecte les protections « bloqué » (jamais lu), saute les dossiers cloud
    /// non téléchargés ou qui ne répondent pas, s'arrête au budget de temps ou sur annulation (résultat partiel mais cohérent).
    /// Taille occupée d'un dossier ou fichier (fts, sans suivre les liens), pour le catalogue « Déplacer ». Budget de temps en secondes.
    static func size(of path: String, budget: TimeInterval = 30) -> Int64 {
        guard let cpath = strdup(path) else { return 0 }
        defer { free(cpath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return 0 }
        defer { fts_close(fts) }
        let deadline = Date().addingTimeInterval(budget)
        var total: Int64 = 0, n = 0
        while let e = fts_read(fts) {
            n += 1
            if n % 1024 == 0, Date() > deadline { break }
            switch Int32(e.pointee.fts_info) {
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT: total += Int64(e.pointee.fts_statp.pointee.st_blocks) * 512
            default: break
            }
        }
        return total
    }

    static func scan(_ rootURL: URL, budget: TimeInterval = 600, control: Control = Control(), extraSkip: Set<String> = [], progress: @escaping (Progress) -> Void = { _ in }) -> Result {
        let start = Date()
        let rootPath = rootURL.standardizedFileURL.path
        let blocked = Set(Ignore.hard + Ignore.userPaths).union(skip).union(extraSkip)
        let root = SNode(name: rootPath, size: 0, isDir: true)
        var result = Result(root: root, partial: false, entries: 0, seconds: 0, unreadable: 0, skipped: [])
        guard let cpath = strdup(rootPath) else { return result }
        defer { free(cpath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return result }
        defer { fts_close(fts) }

        var stack: [Frame] = []
        var bytes: Int64 = 0
        var lastReport = Date()
        var rootStat = stat()
        let rootDev: dev_t? = stat(rootPath, &rootStat) == 0 ? rootStat.st_dev : nil
        /// Même volume qu'au départ ? (un volume débranché laisse un point de montage vide sur un autre disque, ou plus rien)
        func volumeIntact() -> Bool {
            guard let rootDev else { return true }
            var s = stat()
            return stat(rootPath, &s) == 0 && s.st_dev == rootDev
        }

        func attach(_ node: SNode, to frame: Frame?) {
            guard let frame else { return }
            frame.bytes += node.isDir ? node.size : 0
            frame.kids.append(node)
        }
        func finish(_ f: Frame) {
            let node = f.node
            node.size = f.bytes
            let kids = f.kids.sorted { $0.size > $1.size }
            let floor = max(keepMin, node.size / 500)
            node.children = Array(kids.prefix(maxKids).filter { $0.size >= floor })
            node.children.forEach { $0.parent = node }
        }

        while let e = fts_read(fts) {
            let info = Int32(e.pointee.fts_info)
            let level = Int(e.pointee.fts_level)
            result.entries += 1
            if result.entries % 512 == 0 {
                if control.cancelled || Date().timeIntervalSince(start) > budget { result.partial = true; break }
                if !volumeIntact() { result.partial = true; result.volumeLost = true; break }
                if Date().timeIntervalSince(lastReport) > 0.4 {
                    lastReport = Date()
                    progress(Progress(entries: result.entries, bytes: bytes, current: String(cString: e.pointee.fts_path)))
                }
            }
            func name() -> String {
                let off = Int(e.pointee.fts_pathlen) - Int(e.pointee.fts_namelen)
                return String(cString: e.pointee.fts_path + off)
            }
            switch info {
            case FTS_D:
                let path = String(cString: e.pointee.fts_path)
                let st = e.pointee.fts_statp.pointee
                if level > 0 {
                    var why: String?
                    if blocked.contains(path) { why = path }
                    else if st.st_flags & 0x40000000 != 0 { why = path }   // SF_DATALESS : dossier cloud jamais téléchargé
                    else if let parent = stack.last?.node.name, parent == "CloudStorage" || parent == "Mobile Documents",
                            !FS.responds(URL(fileURLWithPath: path)) { why = path }
                    if let why {
                        result.skipped.append(why)
                        let f = Frame(root); f.skipped = true
                        stack.append(f)
                        fts_set(fts, e, FTS_SKIP)
                        continue
                    }
                }
                let node = level == 0 ? root : SNode(name: name(), size: 0, isDir: true)
                stack.append(Frame(node))
            case FTS_DP:
                guard let f = stack.popLast(), !f.skipped else { continue }
                finish(f)
                if level > 0 { attach(f.node, to: stack.last) }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let frame = stack.last else { continue }
                let size = Int64(e.pointee.fts_statp.pointee.st_blocks) * 512
                bytes += size
                frame.bytes += size
                if size >= fileNode { frame.kids.append(SNode(name: name(), size: size, isDir: false)) }
            case FTS_DNR:
                // Dossier illisible : fts le renvoie en pré-ordre (FTS_D) puis ici, sans post-ordre : le cadre ouvert doit être refermé.
                result.unreadable += 1
                if let f = stack.popLast() { finish(f); if level > 0 { attach(f.node, to: stack.last) } }
            case FTS_ERR, FTS_NS:
                result.unreadable += 1
            default: break
            }
        }
        // Budget dépassé ou annulation : les dossiers ouverts sont refermés avec ce qu'ils contiennent.
        while let f = stack.popLast() {
            if f.skipped { continue }
            finish(f)
            if f.node !== root { attach(f.node, to: stack.last) }
        }
        if !result.volumeLost, !volumeIntact() { result.partial = true; result.volumeLost = true }
        result.seconds = Date().timeIntervalSince(start)
        progress(Progress(entries: result.entries, bytes: bytes, current: ""))
        return result
    }

    // MARK: Cache sur disque

    struct DTO: Codable {
        var n: String; var s: Int64; var d: Bool; var c: [DTO]
        init(_ x: SNode) { n = x.name; s = x.size; d = x.isDir; c = x.children.map(DTO.init) }
        func node() -> SNode {
            let x = SNode(name: n, size: s, isDir: d)
            x.children = c.map { $0.node() }
            x.children.forEach { $0.parent = x }
            return x
        }
    }

    struct Cached: Codable {
        var root: DTO
        var date: Date
        var partial: Bool
        var entries: Int
        var seconds: Double
        var version: Int
    }

    static func cacheURL(_ root: URL) -> URL {
        let slug = root.standardizedFileURL.path.replacingOccurrences(of: "/", with: "_")
        return FS.support.appendingPathComponent("stockage\(slug == "_" ? "_racine" : slug).json")
    }

    static func save(_ r: Result, root: URL) {
        let c = Cached(root: DTO(r.root), date: Date(), partial: r.partial, entries: r.entries, seconds: r.seconds, version: rulesVersion)
        try? FileManager.default.createDirectory(at: FS.support, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(c).write(to: cacheURL(root), options: .atomic)
    }

    static func load(_ root: URL) -> (root: SNode, info: Cached)? {
        guard let d = try? Data(contentsOf: cacheURL(root)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let c = try? dec.decode(Cached.self, from: d), c.version == rulesVersion else { return nil }
        return (c.root.node(), c)
    }
}

// MARK: - Totaux par catégorie et par zone

/// Grandes zones d'un récapitulatif : un nom et les dossiers qui la composent.
struct StorageZone: Sendable {
    let name: String
    let paths: [String]
}

struct StorageStats: Sendable {
    var total: Int64 = 0
    var byCategory: [StorageCategory: Int64] = [:]
    /// Même ordre que les zones fournies ; la dernière ligne est « Autres » (hors zones).
    var byZone: [[StorageCategory: Int64]] = []
    var zoneNames: [String] = []
    /// Dossiers « Inconnu » les plus hauts dans l'arbre (le parent n'est pas Inconnu), du plus gros au plus petit.
    var unknown: [(path: String, size: Int64)] = []
}

enum StorageAnalysis {
    static let unanalysedName = "Non analysé"

    /// Espace utilisé du volume, comme dans Réglages Système (capacité moins l'espace disponible, purgeable compris).
    static func volumeUsed(_ url: URL) -> Int64? {
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int64(total) - free
    }

    /// Secteur « Non analysé » : espace utilisé du volume moins ce qui a été analysé (volume système scellé, swap, instantanés, dossiers
    /// inaccessibles), pour que le total corresponde aux Réglages Système. Rien si l'écart est inférieur à 100 Mo. Retourne la taille ajoutée.
    @discardableResult
    static func addUnanalysed(to root: SNode, volume: URL, used: Int64? = nil) -> Int64 {
        if let k = root.children.firstIndex(where: { $0.name == unanalysedName && $0.cls?.rule == "non-analyse" }) {
            root.size -= root.children[k].size; root.children.remove(at: k)
        }
        guard let used = used ?? volumeUsed(volume), used - root.size >= 100_000_000 else { return 0 }
        let extra = used - root.size
        let n = SNode(name: unanalysedName, size: extra, isDir: false)
        n.cls = Classification(category: .system, reason: "Volume système scellé, swap, instantanés locaux et dossiers inaccessibles : comptés par macOS, non parcourus par zerOS", rule: "non-analyse")
        n.parent = root
        root.children.append(n); root.size += extra
        return extra
    }

    /// Zones de l'ensemble du disque interne.
    static func diskZones(home: String = FS.home.path) -> [StorageZone] {
        [StorageZone(name: "Apps", paths: ["/Applications", home + "/Applications"]),
         StorageZone(name: "Bibliothèque de l'utilisateur", paths: [home + "/Library"]),
         StorageZone(name: "Dossier personnel (hors Bibliothèque)", paths: [home]),
         StorageZone(name: "Bibliothèque système", paths: ["/Library"]),
         StorageZone(name: "Partagé", paths: ["/Users/Shared"]),
         StorageZone(name: "Données macOS", paths: ["/private", "/opt", "/usr"])]
    }

    /// Périmètre des « Données système » de macOS (SPEC.md).
    static func systemDataZones(home: String = FS.home.path) -> [StorageZone] {
        [StorageZone(name: "Bibliothèque de l'utilisateur", paths: [home + "/Library"]),
         StorageZone(name: "Bibliothèque système", paths: ["/Library"]),
         StorageZone(name: "Données variables (/private/var)", paths: ["/private/var"]),
         StorageZone(name: "Partagé (/Users/Shared)", paths: ["/Users/Shared"]),
         StorageZone(name: "Ressources macOS (AssetsV2)", paths: ["/System/Library/AssetsV2"])]
    }

    /// Les nœuds d'un périmètre : ceux des chemins qui existent dans l'arbre.
    static func nodes(for zones: [StorageZone], in root: SNode) -> [SNode] {
        zones.flatMap(\.paths).compactMap { root.find($0) }
    }

    /// Répartit chaque octet dans la catégorie du plus petit nœud qui le contient (octets propres du nœud). `onlyPaths` : les
    /// racines du périmètre ; sans zone correspondante, l'octet tombe dans la dernière ligne « Autres ».
    static func compute(roots: [SNode], zones: [StorageZone], context: ClassContext, unknownMin: Int64 = 0) -> StorageStats {
        let table = Dictionary(Classifier.rules(home: context.home).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var stats = StorageStats()
        stats.zoneNames = zones.map(\.name) + ["Autres"]
        stats.byZone = Array(repeating: [:], count: zones.count + 1)
        var zoneOf: [String: Int] = [:]
        for (i, z) in zones.enumerated() { for p in z.paths where zoneOf[p] == nil { zoneOf[p] = i } }

        /// Retourne vrai si le nœud ou un de ses descendants a une règle propre (autre que « defaut »).
        @discardableResult
        func visit(_ n: SNode, path: String, zone: Int) -> Bool {
            let zone = zoneOf[path] ?? zone
            let c = n.cls ?? Classifier.classify(path, context: context, rules: table)
            n.cls = c
            let own = n.own
            stats.total += own
            stats.byCategory[c.category, default: 0] += own
            stats.byZone[zone][c.category, default: 0] += own
            var ruledBelow = false
            for k in n.children where visit(k, path: path == "/" ? "/" + k.name : path + "/" + k.name, zone: zone) { ruledBelow = true }
            n.structural = c.rule == "defaut" && ruledBelow
            return c.rule != "defaut" || ruledBelow
        }
        /// Inconnus à décider : on traverse les dossiers de regroupement et on s'arrête au premier dossier « Inconnu » qui n'en est pas un
        /// (inutile de lister ses sous-dossiers : c'est lui qu'il faut classer).
        func report(_ n: SNode, _ path: String) {
            guard let c = n.cls, n.size >= unknownMin, n.size > 0 else { return }
            if c.category != .unknown || n.structural {
                for k in n.children { report(k, path == "/" ? "/" + k.name : path + "/" + k.name) }
                if c.category == .unknown, n.own >= unknownMin { stats.unknown.append((path + " (fichiers et petits dossiers)", n.own)) }
            } else {
                stats.unknown.append((path, n.size))
            }
        }
        for r in roots { visit(r, path: r.path, zone: zones.count); report(r, r.path) }
        stats.unknown.sort { $0.size > $1.size }
        return stats
    }
}
