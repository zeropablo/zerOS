import Foundation
import AppKit

struct CloudProvider: Identifiable, Hashable {
    var id: String { root.path }
    let name: String
    let root: URL
    let symbol: String
    var responsive = true
}

enum CloudCleanup {
    static func providers() -> [CloudProvider] {
        var out: [CloudProvider] = []
        let icloud = FS.lib("Mobile Documents/com~apple~CloudDocs")
        if FS.exists(icloud) { out.append(CloudProvider(name: "iCloud Drive", root: icloud, symbol: "icloud")) }
        for c in FS.children(FS.lib("CloudStorage")) {
            let n = c.lastPathComponent
            if n.lowercased().hasPrefix("icloud") { continue }
            let (name, sym): (String, String)
            if n.hasPrefix("GoogleDrive") { name = "Google Drive" + account(n); sym = "externaldrive.connected.to.line.below" }
            else if n.hasPrefix("Dropbox") { name = "Dropbox" + account(n); sym = "shippingbox" }
            else if n.hasPrefix("OneDrive") { name = "OneDrive" + account(n); sym = "cloud" }
            else if n.hasPrefix("Box") { name = "Box" + account(n); sym = "cube" }
            else { name = n; sym = "cloud" }
            out.append(CloudProvider(name: name, root: c, symbol: sym))
        }
        out = out.map { var p = $0; p.responsive = FS.responds(p.root); return p }
        let legacy = FS.h("Dropbox")
        if FS.exists(legacy), !FS.isSymlink(legacy), !out.contains(where: { $0.name.hasPrefix("Dropbox") }) {
            out.append(CloudProvider(name: "Dropbox", root: legacy, symbol: "shippingbox"))
        }
        return out
    }

    /// A folder whose content has never been downloaded. Opening it would make macOS fetch it from the internet.
    static func isDatalessDir(_ u: URL) -> Bool {
        var st = stat()
        guard lstat(u.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        return (st.st_flags & 0x40000000) != 0   // SF_DATALESS
    }

    static func account(_ n: String) -> String {
        guard let r = n.firstIndex(of: "-") else { return "" }
        return " (" + n[n.index(after: r)...] + ")"
    }

    static func scan(_ rep: Reporter) async -> [CleanGroup] {
        var groups: [CleanGroup] = []
        var cloudIndex: [String: [URL]] = [:]   // "name|size" → cloud files on this Mac
        var dead: [CleanItem] = []
        for p in providers() {
            guard p.responsive else {
                dead.append(CleanItem(title: p.name, subtitle: "Ce service cloud ne répond pas : ouvrez son app (ou reconnectez-vous) puis relancez l'analyse.", mode: .none, preselected: false, symbol: "exclamationmark.icloud"))
                continue
            }
            rep("Analyse de \(p.name)…")
            var local: [CleanItem] = [], big: [CleanItem] = []
            var n = 0
            let deadline = Date().addingTimeInterval(120)
            FS.walk(p.root, keys: [.totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey],
                    skipHidden: true, skipPackages: true, exclude: isDatalessDir) { f, v in
                if v.isDirectory == true && v.isPackage != true { return Date() < deadline }
                n += 1
                rep.tick("\(p.name) : \(n) fichiers…")
                let onDisk = v.isPackage == true ? FS.allocatedSize(f) : Int64(v.totalFileAllocatedSize ?? 0)
                let logical = Int64(v.fileSize ?? 0)
                let rel = f.path.replacingOccurrences(of: p.root.path, with: p.name)
                if onDisk > 1_000_000 {
                    local.append(CleanItem(url: f, title: f.lastPathComponent, subtitle: rel, size: onDisk, date: v.contentModificationDate,
                                           mode: .custom("evict"), preselected: false, iconPath: f.path))
                    cloudIndex["\(f.lastPathComponent)|\(logical)", default: []].append(f)
                }
                if max(logical, onDisk) > 100_000_000 {
                    big.append(CleanItem(url: f, title: f.lastPathComponent, subtitle: rel + (onDisk == 0 ? " · seulement en ligne" : ""),
                                         size: max(logical, onDisk), date: v.contentModificationDate, mode: .trash, preselected: false, iconPath: f.path))
                }
                return true
            }
            if !local.isEmpty {
                groups.append(CleanGroup(id: "cloud.local.\(p.name)", title: "\(p.name) — sur ce Mac", subtitle: "Fichiers du cloud téléchargés localement",
                                         symbol: p.symbol, items: Array(local.sorted { $0.size > $1.size }.prefix(3000)),
                                         note: "« Libérer sur ce Mac » retire la copie locale : le fichier reste dans le cloud et se retélécharge quand vous l'ouvrez."))
            }
            if !big.isEmpty {
                groups.append(CleanGroup(id: "cloud.big.\(p.name)", title: "\(p.name) — gros fichiers", subtitle: "Ce qui remplit votre espace en ligne",
                                         symbol: "arrow.up.bin", items: Array(big.sorted { $0.size > $1.size }.prefix(500)),
                                         note: "« Supprimer partout » efface le fichier du cloud et de tous vos appareils (il passe d'abord par la Corbeille)."))
            }
        }
        rep("Recherche de copies en double hors du cloud…")
        var dupes: [CleanItem] = []
        for root in ["Desktop", "Documents", "Downloads", "Movies", "Pictures"].map(FS.h) {
            FS.walk(root, keys: [.fileSizeKey, .totalFileAllocatedSizeKey], skipPackages: true, exclude: Clutter.excludedFromHome) { f, v in
                guard v.isDirectory != true, let s = v.fileSize, s > 1_000_000,
                      let twins = cloudIndex["\(f.lastPathComponent)|\(s)"], !twins.contains(where: { $0.path == f.path }) else { return true }
                if let twin = twins.first, Clutter.hash(f, partial: true) == Clutter.hash(twin, partial: true) {
                    dupes.append(CleanItem(url: f, title: f.lastPathComponent, subtitle: "Déjà présent dans le cloud · " + f.deletingLastPathComponent().path.replacingOccurrences(of: FS.home.path, with: "~"),
                                           size: Int64(v.totalFileAllocatedSize ?? s), mode: .trash, preselected: false, iconPath: f.path))
                }
                return true
            }
        }
        if !dupes.isEmpty {
            groups.insert(CleanGroup(id: "cloud.dupes", title: "Copies locales en double", subtitle: "Fichiers déjà sauvegardés dans le cloud",
                                     symbol: "doc.on.doc", items: dupes.sorted { $0.size > $1.size },
                                     note: "Ces fichiers existent à l'identique dans votre cloud. La copie locale part à la Corbeille, celle du cloud est gardée."), at: 0)
        }
        return groups
    }

    static func evict(_ u: URL) -> (Bool, Int64, String?) {
        let before = FS.allocatedSize(u)
        do { try FileManager.default.evictUbiquitousItem(at: u) } catch {
            if !Shell.run("/usr/bin/fileproviderctl", ["evict", u.path]).ok, !Shell.run("/usr/bin/brctl", ["evict", u.path]).ok {
                return (false, 0, "Le service cloud a refusé de libérer ce fichier")
            }
        }
        Thread.sleep(forTimeInterval: 0.05)
        return (true, max(0, before - FS.allocatedSize(u)), nil)
    }
}
