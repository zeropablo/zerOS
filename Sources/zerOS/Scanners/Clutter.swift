import Foundation
import AppKit
import CryptoKit
import Vision
import UniformTypeIdentifiers
import ImageIO

enum Clutter {
    static func excludedFromHome(_ u: URL) -> Bool {
        let p = u.path
        let skip = ["/Library", "/.Trash", "/Applications", "/.claude"].map { FS.home.path + $0 }
        return skip.contains { p == $0 || p.hasPrefix($0 + "/") } || Ignore.blocked(u)
    }

    static func kind(_ u: URL, isPackage: Bool) -> (String, String) {
        if isPackage { return ("Bibliothèques & paquets", "shippingbox") }
        guard let t = UTType(filenameExtension: u.pathExtension.lowercased()) else { return ("Autres", "doc") }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return ("Vidéos", "film") }
        if t.conforms(to: .audio) { return ("Musique & audio", "music.note") }
        if t.conforms(to: .image) { return ("Images", "photo") }
        if t.conforms(to: .archive) || t.conforms(to: .diskImage) || ["dmg", "iso", "zip", "rar", "7z"].contains(u.pathExtension.lowercased()) { return ("Archives & images disque", "archivebox") }
        if t.conforms(to: .pdf) || t.conforms(to: .text) || t.conforms(to: .presentation) || t.conforms(to: .spreadsheet) { return ("Documents", "doc.text") }
        return ("Autres", "doc")
    }

    // MARK: Large & old files

    static func largeOld(_ rep: Reporter, minLarge: Int64 = 50_000_000) async -> [CleanGroup] {
        var buckets: [String: (String, [CleanItem])] = [:]
        let yearAgo = Date().addingTimeInterval(-365 * 86400)
        var n = 0
        FS.walk(FS.home, keys: [.totalFileAllocatedSizeKey, .contentAccessDateKey, .contentModificationDateKey], skipPackages: true, exclude: excludedFromHome) { f, v in
            n += 1
            rep.tick("Analyse de \(n) fichiers… \(f.lastPathComponent)")
            let isPkg = v.isPackage == true
            if v.isDirectory == true && !isPkg { return true }
            let size = isPkg ? FS.allocatedSize(f) : Int64(v.totalFileAllocatedSize ?? 0)
            let last = FS.newest(v.contentAccessDate, v.contentModificationDate)
            let old = (last ?? .distantPast) < yearAgo
            guard size >= minLarge || (old && size >= 10_000_000) else { return true }
            let (k, sym) = kind(f, isPackage: isPkg)
            let tag = size >= minLarge ? (old ? "Gros et ancien" : "Gros fichier") : "Pas ouvert depuis plus d'un an"
            var b = buckets[k] ?? (sym, [])
            b.1.append(CleanItem(url: f, title: f.lastPathComponent,
                                 subtitle: "\(tag) · \(f.deletingLastPathComponent().path.replacingOccurrences(of: FS.home.path, with: "~"))",
                                 size: size, date: last, mode: .trash, preselected: false, iconPath: f.path))
            buckets[k] = b
            return true
        }
        let order = ["Vidéos", "Archives & images disque", "Bibliothèques & paquets", "Musique & audio", "Images", "Documents", "Autres"]
        return order.compactMap { k in
            guard let (sym, items) = buckets[k] else { return nil }
            return CleanGroup(id: "large.\(k)", title: k, subtitle: Fmt.count(items.count, "fichier"), symbol: sym, items: items.sorted { $0.size > $1.size },
                              note: "Rien n'est coché : ce sont vos fichiers. Ce que vous sélectionnez part à la Corbeille.")
        }
    }

    // MARK: Duplicates

    static func hash(_ u: URL, partial: Bool) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: u) else { return nil }
        defer { try? fh.close() }
        var h = SHA256()
        if partial {
            if let d = try? fh.read(upToCount: 65_536) { h.update(data: d) }
            if let end = try? fh.seekToEnd(), end > 131_072 {
                try? fh.seek(toOffset: end - 65_536)
                if let d = try? fh.read(upToCount: 65_536) { h.update(data: d) }
            }
        } else {
            while let d = try? fh.read(upToCount: 1_048_576), !d.isEmpty { h.update(data: d) }
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func duplicates(_ rep: Reporter, roots: [URL]? = nil, minSize: Int64 = 100_000) async -> [CleanGroup] {
        let roots = roots ?? ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"].map(FS.h)
        var bySize: [Int64: [(URL, Date?)]] = [:]
        var n = 0
        for root in roots {
            FS.walk(root, keys: [.fileSizeKey, .creationDateKey], skipPackages: true, exclude: excludedFromHome) { f, v in
                guard v.isDirectory != true, v.isSymbolicLink != true, let s = v.fileSize, Int64(s) >= minSize else { return true }
                n += 1
                rep.tick("Inventaire : \(n) fichiers…")
                bySize[Int64(s), default: []].append((f, v.creationDate))
                return true
            }
        }
        let candidates = bySize.filter { $0.value.count > 1 }
        var sets: [(Int64, [(URL, Date?)])] = []
        var done = 0
        for (size, files) in candidates {
            done += 1
            rep.tick("Comparaison \(done)/\(candidates.count)…")
            var byPartial: [String: [(URL, Date?)]] = [:]
            for f in files { if let h = hash(f.0, partial: true) { byPartial[h, default: []].append(f) } }
            for group in byPartial.values where group.count > 1 {
                var byFull: [String: [(URL, Date?)]] = [:]
                if size <= 131_072 { byFull["p"] = group }
                else { for f in group { if let h = hash(f.0, partial: false) { byFull[h, default: []].append(f) } } }
                for g in byFull.values where g.count > 1 { sets.append((size, g)) }
            }
        }
        sets.sort { $0.0 * Int64($0.1.count - 1) > $1.0 * Int64($1.1.count - 1) }
        return sets.prefix(1500).enumerated().map { idx, s in
            // Keep the oldest copy, preferably outside Downloads.
            let ordered = s.1.sorted { a, b in
                let ad = a.0.path.contains("/Downloads/"), bd = b.0.path.contains("/Downloads/")
                if ad != bd { return !ad }
                return (a.1 ?? .distantFuture) < (b.1 ?? .distantFuture)
            }
            let items = ordered.enumerated().map { i, f in
                CleanItem(url: f.0, title: f.0.lastPathComponent,
                          subtitle: (i == 0 ? "Copie gardée · " : "") + f.0.deletingLastPathComponent().path.replacingOccurrences(of: FS.home.path, with: "~"),
                          size: s.0, date: f.1, mode: .trash, preselected: false, iconPath: f.0.path)
            }
            return CleanGroup(id: "dup.\(idx)", title: ordered[0].0.lastPathComponent, subtitle: "\(s.1.count) copies identiques",
                              symbol: "doc.on.doc", items: items, note: "Rien n'est coché : ce sont vos fichiers. Cochez les copies à jeter, elles partent à la Corbeille. Une copie est toujours gardée.", keepOne: true)
        }
    }

    // MARK: Similar images

    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp"]

    static func pixelCount(_ u: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return 0 }
        return (p[kCGImagePropertyPixelWidth] as? Int ?? 0) * (p[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    static func similarImages(_ rep: Reporter, threshold: Float = 0.38, cap: Int = 3000) async -> [CleanGroup] {
        var files: [(URL, Int64, Date?)] = []
        for root in ["Pictures", "Desktop", "Downloads", "Documents"].map(FS.h) {
            FS.walk(root, keys: [.fileSizeKey, .creationDateKey], skipPackages: true, exclude: excludedFromHome) { f, v in
                guard imageExts.contains(f.pathExtension.lowercased()), let s = v.fileSize, s > 30_000 else { return true }
                files.append((f, Int64(s), v.creationDate))
                return files.count < cap
            }
        }
        let total = files.count
        let urls = files.map(\.0)
        let prints: [(Int, VNFeaturePrintObservation)] = await withTaskGroup(of: (Int, VNFeaturePrintObservation?).self) { g in
            var out: [(Int, VNFeaturePrintObservation)] = []
            var next = 0, processed = 0
            let worker: @Sendable (Int, URL) -> (Int, VNFeaturePrintObservation?) = { i, url in
                let req = VNGenerateImageFeaturePrintRequest()
                let h = VNImageRequestHandler(url: url, options: [:])
                guard (try? h.perform([req])) != nil else { return (i, nil) }
                return (i, req.results?.first)
            }
            while next < min(6, urls.count) { let i = next, u = urls[i]; g.addTask { worker(i, u) }; next += 1 }
            while let r = await g.next() {
                processed += 1
                rep.tick("Analyse visuelle \(processed)/\(total)…")
                if let o = r.1 { out.append((r.0, o)) }
                if next < urls.count { let i = next, u = urls[i]; g.addTask { worker(i, u) }; next += 1 }
            }
            return out
        }
        rep("Regroupement des photos qui se ressemblent…")
        var parent = Array(0..<prints.count)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        for a in 0..<prints.count {
            for b in (a + 1)..<max(a + 1, prints.count) {
                var d: Float = 0
                if (try? prints[a].1.computeDistance(&d, to: prints[b].1)) != nil, d < threshold {
                    parent[find(a)] = find(b)
                }
            }
        }
        var clusters: [Int: [Int]] = [:]
        for i in 0..<prints.count { clusters[find(i), default: []].append(prints[i].0) }
        var groups: [CleanGroup] = []
        for (n, idxs) in clusters.values.filter({ $0.count > 1 }).enumerated() {
            let ranked = idxs.map { ($0, pixelCount(files[$0].0)) }.sorted { ($0.1, files[$0.0].1) > ($1.1, files[$1.0].1) }
            let items = ranked.enumerated().map { pos, r in
                let f = files[r.0]
                return CleanItem(url: f.0, title: f.0.lastPathComponent,
                                 subtitle: (pos == 0 ? "Meilleure qualité, gardée · " : "") + "\(r.1 / 1_000_000) Mpx · " + f.0.deletingLastPathComponent().lastPathComponent,
                                 size: f.1, date: f.2, mode: .trash, preselected: false, iconPath: f.0.path)
            }
            groups.append(CleanGroup(id: "sim.\(n)", title: items[0].title, subtitle: "\(items.count) photos similaires", symbol: "photo.on.rectangle", items: items, note: "Rien n'est coché : ce sont vos photos. Cochez celles à jeter, elles partent à la Corbeille. Une photo est toujours gardée.", keepOne: true))
        }
        return groups.sorted { $0.size > $1.size }
    }

    // MARK: Downloads

    static func downloads(_ rep: Reporter) async -> [CleanGroup] {
        rep("Analyse du dossier Téléchargements…")
        let now = Date()
        var buckets: [Int: [CleanItem]] = [:]
        for f in FS.children(FS.h("Downloads")) {
            let v = try? f.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
            let d = v?.addedToDirectoryDate ?? v?.contentModificationDate
            let age = now.timeIntervalSince(d ?? now)
            let b = age > 365 * 86400 ? 0 : (age > 30 * 86400 ? 1 : 2)
            buckets[b, default: []].append(CleanItem(url: f, title: f.lastPathComponent, subtitle: "Ajouté \(Fmt.ago(d))",
                                                     size: FS.allocatedSize(f), date: d, mode: .trash, preselected: false, iconPath: f.path))
        }
        let titles = [0: ("Plus d'un an", "calendar.badge.exclamationmark"), 1: ("Entre 1 et 12 mois", "calendar"), 2: ("Ce mois-ci", "clock")]
        return [0, 1, 2].compactMap { b in
            guard let items = buckets[b], let t = titles[b] else { return nil }
            return CleanGroup(id: "dl.\(b)", title: t.0, subtitle: Fmt.count(items.count, "élément"), symbol: t.1, items: items.sorted { $0.size > $1.size },
                              note: "Les téléchargements servent souvent une seule fois. Rien n'est coché : choisissez ce qui peut partir à la Corbeille.")
        }
    }
}
