import Foundation
import AppKit

// MARK: - System junk (12 categories)

enum Junk {
    static var runningIDs: Set<String> { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }

    /// True when a cache folder belongs to an app that is open right now (by bundle ID or by vendor/app name).
    static func belongsToRunningApp(_ name: String, ids: Set<String>) -> Bool {
        if ids.contains(where: { name == $0 || name.hasPrefix($0 + ".") }) { return true }
        guard !name.contains(".") else { return false }
        let n = name.lowercased()
        return NSWorkspace.shared.runningApplications.contains { app in
            let l = (app.localizedName ?? "").lowercased()
            let vendor = (app.bundleIdentifier ?? "").split(separator: ".").dropFirst().first.map { String($0).lowercased() } ?? ""
            return l == n || l.hasPrefix(n + " ") || vendor == n
        }
    }

    /// Caches macOS needs to keep (iCloud, Find My, keychain sync…).
    static let protectedCaches: Set<String> = [
        "com.apple.bird", "CloudKit", "com.apple.akd", "FamilyCircle", "com.apple.homed", "com.apple.HomeKit",
        "com.apple.ap.adprivacyd", "com.apple.containermanagerd", "com.apple.nsurlsessiond", "com.apple.iCloudHelper",
        "com.apple.amsengagementd", "GeoServices", "com.apple.findmy.fmipcore", "com.apple.findmy.fmfcore",
        "com.apple.passd", "com.apple.Safari.SafeBrowsing", "com.apple.ctcategories.service", "com.apple.icloud.fmfd",
        "com.apple.iCloudNotificationAgent", "com.apple.cloudd", "com.apple.mediaanalysisd", "com.apple.photoanalysisd",
        "com.apple.WebKit.Networking", "zerOS", "com.zeropablo.zeros",
    ]

    static func scanAll(_ rep: Reporter) async -> [CleanGroup] {
        var out: [CleanGroup] = []
        rep("Caches des apps…"); out.append(userCaches())
        rep("Caches du système…"); out.append(systemCaches())
        rep("Journaux des apps…"); out.append(userLogs())
        rep("Journaux du système…"); out.append(systemLogs())
        rep("Éléments de démarrage cassés…"); out.append(brokenLoginItems())
        rep("Réglages abîmés…"); out.append(brokenPreferences())
        rep("Comptes supprimés…"); out.append(deletedUsers())
        rep("Anciennes versions de documents…"); out.append(documentVersions(rep))
        rep("Sauvegardes iPhone / iPad…"); out.append(iosBackups())
        rep("Langues inutilisées…"); out.append(languageFiles())
        rep("Code Intel inutile…"); out.append(universalBinaries())
        rep("Déchets Xcode…"); out.append(xcodeJunk())
        return out.filter { !$0.items.isEmpty }
    }

    static func sorted(_ items: [CleanItem]) -> [CleanItem] { items.sorted { $0.size > $1.size } }

    // 1. App caches
    static func userCaches() -> CleanGroup {
        let running = runningIDs
        var items: [CleanItem] = []
        for d in FS.children(FS.lib("Caches")) {
            let name = d.lastPathComponent
            if protectedCaches.contains(name) || CacheScan.handledNames.contains(name) || AIClutter.isAIName(name) || Ignore.blocked(d)
                || Prefs.ignoredDevCaches.contains(d.path) { continue }
            let size = FS.allocatedSize(d)
            guard size > 100_000 else { continue }
            let appURL = FS.appURL(forBundleID: name)
            let isRunning = belongsToRunningApp(name, ids: running)
            items.append(CleanItem(url: d,
                                   title: appURL.map(FS.displayName) ?? name,
                                   subtitle: isRunning ? "App ouverte — décoché pour éviter les soucis" : (appURL != nil ? name : "Cache"),
                                   size: size,
                                   mode: FS.isDir(d) ? .emptyDir : .delete,
                                   preselected: !isRunning,
                                   iconPath: appURL?.path))
        }
        // Sandboxed apps keep their caches in their container.
        if Perms.fullDiskAccess {
            for c in FS.children(FS.lib("Containers")) {
                let id = c.lastPathComponent
                if id.hasPrefix("com.apple.") || protectedCaches.contains(id) || AIClutter.isAIName(id) { continue }
                let cache = c.appendingPathComponent("Data/Library/Caches")
                let size = FS.allocatedSize(cache)
                guard size > 1_000_000 else { continue }
                let appURL = FS.appURL(forBundleID: id)
                let isRunning = running.contains(id)
                items.append(CleanItem(url: cache, title: appURL.map(FS.displayName) ?? id,
                                       subtitle: isRunning ? "App ouverte — décoché" : "Cache d'app protégée",
                                       size: size, mode: .emptyDir, preselected: !isRunning, iconPath: appURL?.path))
            }
        }
        // Developer tool caches.
        let devCaches = [".npm/_cacache": "npm", ".cache/pip": "pip", ".cache/yarn": "Yarn", ".gradle/caches": "Gradle",
                         ".cargo/registry/cache": "Cargo", "go/pkg/mod/cache": "Go"]
        for (p, n) in devCaches {
            let u = FS.h(p)
            let size = FS.allocatedSize(u)
            if size > 1_000_000 { items.append(CleanItem(url: u, title: "Cache \(n)", subtitle: "Outil de développement", size: size, mode: .emptyDir, symbol: "hammer")) }
        }
        for c in FS.children(FS.h(".cache")) where !AIClutter.dotCacheAI.contains(c.lastPathComponent) && !Prefs.ignoredDevCaches.contains(c.path) {
            let size = FS.allocatedSize(c)
            if size > 1_000_000 { items.append(CleanItem(url: c, title: c.lastPathComponent, subtitle: "~/.cache", size: size, mode: FS.isDir(c) ? .emptyDir : .delete, symbol: "terminal")) }
        }
        return CleanGroup(id: "userCache", title: "Caches des apps", subtitle: "Fichiers temporaires recréés automatiquement",
                          symbol: "shippingbox", items: sorted(items),
                          note: "Les apps gardent des copies temporaires pour aller plus vite. Elles se recréent toutes seules si besoin. Les apps ouvertes sont décochées : fermez-les pour les nettoyer aussi.", regenerable: true)
    }

    // 2. System caches
    static func systemCaches() -> CleanGroup {
        var items: [CleanItem] = []
        for d in FS.children(URL(fileURLWithPath: "/Library/Caches")) {
            let name = d.lastPathComponent
            let size = FS.allocatedSize(d)
            guard size > 500_000 else { continue }
            let apple = name.hasPrefix("com.apple")
            items.append(CleanItem(url: d, title: name, subtitle: apple ? "Composant macOS — décoché par prudence" : "Cache partagé",
                                   size: size, mode: FS.isDir(d) ? .adminEmpty : .admin, preselected: !apple, symbol: "gearshape.2"))
        }
        return CleanGroup(id: "systemCache", title: "Caches du système", subtitle: "Caches partagés par tous les comptes",
                          symbol: "gearshape.2", items: sorted(items),
                          note: "Demande votre mot de passe administrateur. Les caches propres à macOS sont décochés par défaut.", regenerable: true)
    }

    // 3. App logs
    static func userLogs() -> CleanGroup {
        var items: [CleanItem] = []
        for d in FS.children(FS.lib("Logs")) {
            if AIClutter.isAIName(d.lastPathComponent) { continue }
            let size = FS.allocatedSize(d)
            guard size > 20_000 else { continue }
            items.append(CleanItem(url: d, title: d.lastPathComponent == "DiagnosticReports" ? "Rapports de plantage" : d.lastPathComponent,
                                   subtitle: "~/Library/Logs", size: size, mode: FS.isDir(d) ? .emptyDir : .delete, symbol: "doc.text"))
        }
        return CleanGroup(id: "userLogs", title: "Journaux des apps", subtitle: "Historique technique des apps",
                          symbol: "doc.text", items: sorted(items),
                          note: "Des notes techniques que les apps écrivent pour leurs développeurs. Inutiles au quotidien.", regenerable: true)
    }

    // 4. System logs
    static func systemLogs() -> CleanGroup {
        var items: [CleanItem] = []
        for d in FS.children(URL(fileURLWithPath: "/Library/Logs")) {
            let size = FS.allocatedSize(d)
            guard size > 50_000 else { continue }
            items.append(CleanItem(url: d, title: d.lastPathComponent, subtitle: "/Library/Logs", size: size,
                                   mode: FS.isDir(d) ? .adminEmpty : .admin, symbol: "doc.text.fill"))
        }
        let rotated = try? NSRegularExpression(pattern: "\\.(gz|bz2|\\d+)$")
        for f in FS.children(URL(fileURLWithPath: "/private/var/log")) {
            let n = f.lastPathComponent
            guard rotated?.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil else { continue }
            let size = FS.allocatedSize(f)
            if size > 10_000 { items.append(CleanItem(url: f, title: n, subtitle: "Ancien journal archivé", size: size, mode: .admin, symbol: "archivebox")) }
        }
        return CleanGroup(id: "systemLogs", title: "Journaux du système", subtitle: "Anciens journaux de macOS",
                          symbol: "doc.text.fill", items: sorted(items), note: "Demande votre mot de passe administrateur.", regenerable: true)
    }

    // 5. Broken login items
    static func brokenLoginItems() -> CleanGroup {
        var items: [CleanItem] = []
        let dirs: [(URL, Bool)] = [(FS.lib("LaunchAgents"), false),
                                   (URL(fileURLWithPath: "/Library/LaunchAgents"), true),
                                   (URL(fileURLWithPath: "/Library/LaunchDaemons"), true)]
        for (dir, system) in dirs {
            for f in FS.children(dir) where f.pathExtension == "plist" {
                guard let d = FS.plist(f) else { continue }
                let prog = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first
                guard let prog, prog.hasPrefix("/"), !FS.exists(URL(fileURLWithPath: prog)) else { continue }
                items.append(CleanItem(url: f, title: (d["Label"] as? String) ?? f.lastPathComponent,
                                       subtitle: "Pointe vers une app disparue : \(prog)", size: FS.allocatedSize(f),
                                       mode: system ? .adminTrash : .trash, preselected: false, symbol: "link.badge.plus"))
            }
        }
        return CleanGroup(id: "brokenLogin", title: "Éléments de démarrage cassés", subtitle: "Lanceurs d'apps qui n'existent plus",
                          symbol: "bolt.horizontal.circle", items: items,
                          note: "Ces lanceurs essaient de démarrer des apps qui ont été supprimées. Rien n'est coché ; ils vont à la Corbeille.")
    }

    // 6. Broken preferences
    static func brokenPreferences() -> CleanGroup {
        var items: [CleanItem] = []
        for dir in [FS.lib("Preferences"), FS.lib("Preferences/ByHost")] {
            for f in FS.children(dir) where f.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: f) else { continue }
                let ok = !data.isEmpty && (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil
                if !ok { items.append(CleanItem(url: f, title: f.lastPathComponent, subtitle: "Fichier de réglages illisible", size: FS.allocatedSize(f), mode: .trash, preselected: false, symbol: "exclamationmark.triangle")) }
            }
        }
        return CleanGroup(id: "brokenPrefs", title: "Réglages abîmés", subtitle: "Fichiers de réglages endommagés",
                          symbol: "slider.horizontal.3", items: items,
                          note: "Un fichier de réglages abîmé peut faire planter une app. L'app en recrée un propre au prochain lancement. Rien n'est coché ; ils vont à la Corbeille.")
    }

    // 7. Deleted users
    static func deletedUsers() -> CleanGroup {
        let items = FS.children(URL(fileURLWithPath: "/Users/Deleted Users")).map {
            CleanItem(url: $0, title: $0.lastPathComponent, subtitle: "Dossier d'un compte supprimé", size: FS.allocatedSize($0), mode: .adminTrash, preselected: false, symbol: "person.crop.circle.badge.xmark")
        }
        return CleanGroup(id: "deletedUsers", title: "Comptes supprimés", subtitle: "Dossiers d'anciens utilisateurs",
                          symbol: "person.2.slash", items: items, note: "Vérifiez qu'il n'y a plus rien d'important dedans. Ils vont à la Corbeille (mot de passe administrateur demandé).")
    }

    // 8. Document versions
    static let docExts: Set<String> = ["pages", "numbers", "key", "txt", "rtf", "rtfd", "md", "docx", "xlsx", "pptx", "pdf", "csv"]

    static func documentVersions(_ rep: Reporter) -> CleanGroup {
        var items: [CleanItem] = []
        var scanned = 0
        let cutoff = Date().addingTimeInterval(-2 * 365 * 86400)
        for root in [FS.h("Documents"), FS.h("Desktop")] {
            FS.walk(root, keys: [.contentModificationDateKey]) { f, v in
                guard docExts.contains(f.pathExtension.lowercased()), (v.contentModificationDate ?? .distantPast) > cutoff else { return true }
                scanned += 1
                if scanned > 1500 { return false }
                guard let versions = NSFileVersion.otherVersionsOfItem(at: f), versions.count > 1 else { return true }
                let extra = versions.count - 1
                let size = versions.dropFirst().reduce(Int64(0)) { $0 + FS.allocatedSize($1.url) }
                items.append(CleanItem(url: f, title: f.lastPathComponent, subtitle: "\(extra) ancienne(s) version(s) — la première et la dernière sont gardées",
                                       size: size, mode: .none, preselected: false, payload: f.path, iconPath: f.path))
                return true
            }
        }
        return CleanGroup(id: "docVersions", title: "Versions de documents", subtitle: "Anciennes versions enregistrées automatiquement",
                          symbol: "clock.arrow.circlepath", items: sorted(items),
                          note: "macOS garde l'historique de vos documents. Analyse seule : une version supprimée ne passe pas par la Corbeille, zerOS n'y touche donc pas. Pour en retirer : Fichier > Revenir à > Parcourir toutes les versions, dans l'app du document.", infoOnly: true)
    }

    // 9. iOS device backups
    static func iosBackups() -> CleanGroup {
        var items: [CleanItem] = []
        for b in FS.children(FS.lib("Application Support/MobileSync/Backup")) {
            let info = FS.plist(b.appendingPathComponent("Info.plist"))
            let name = info?["Device Name"] as? String ?? "Appareil inconnu"
            let date = info?["Last Backup Date"] as? Date
            items.append(CleanItem(url: b, title: "Sauvegarde de \(name)", subtitle: "Dernière sauvegarde : \(Fmt.date(date))",
                                   size: FS.allocatedSize(b), date: date, mode: .trash, preselected: false, symbol: "iphone"))
        }
        items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        if !items.isEmpty { items[0].subtitle += " · la plus récente" }
        return CleanGroup(id: "iosBackups", title: "Sauvegardes iPhone / iPad", subtitle: "Copies de vos appareils stockées sur le Mac",
                          symbol: "iphone", items: items, note: "Rien n'est coché : ce sont vos données. Ce que vous cochez part à la Corbeille.")
    }

    // 10. Language files (analysis only: changing an app breaks its signature)
    static func languageFiles() -> CleanGroup {
        var keep: Set<String> = ["en", "fr", "base"]
        for l in Locale.preferredLanguages { keep.insert(String(l.prefix(2)).lowercased()) }
        let names = ["english": "en", "french": "fr", "german": "de", "japanese": "ja", "spanish": "es", "italian": "it", "dutch": "nl"]
        var items: [CleanItem] = []
        for app in AppCatalog.appURLs() {
            let res = app.appendingPathComponent("Contents/Resources")
            var size: Int64 = 0, n = 0
            for lp in FS.children(res) where lp.pathExtension == "lproj" {
                let raw = lp.deletingPathExtension().lastPathComponent.lowercased()
                let base = names[raw] ?? String(raw.split(whereSeparator: { $0 == "_" || $0 == "-" }).first ?? "")
                if keep.contains(base) { continue }
                size += FS.allocatedSize(lp); n += 1
            }
            if size > 2_000_000 {
                items.append(CleanItem(url: app, title: FS.displayName(app), subtitle: "\(n) langues inutilisées", size: size, mode: .none, preselected: false, iconPath: app.path))
            }
        }
        return CleanGroup(id: "languages", title: "Langues inutilisées", subtitle: "Traductions dont vous n'avez pas besoin",
                          symbol: "character.bubble", items: sorted(items),
                          note: "Analyse seule. Retirer des langues modifie l'app et casse sa signature de sécurité : macOS pourrait refuser de l'ouvrir. zerOS ne les supprime donc pas.",
                          infoOnly: true)
    }

    // 11. Universal binaries (analysis only)
    static func x86SliceSize(_ exe: URL) -> Int64? {
        guard let fh = try? FileHandle(forReadingFrom: exe) else { return nil }
        defer { try? fh.close() }
        guard let d = try? fh.read(upToCount: 8 + 20 * 8) else { return nil }
        let b = [UInt8](d)
        guard b.count >= 8 else { return nil }
        func u32(_ o: Int) -> UInt32 { b[o..<o + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
        guard u32(0) == 0xCAFEBABE else { return nil }
        var x86: Int64 = 0, arm = false
        for i in 0..<min(Int(u32(4)), 8) {
            let o = 8 + i * 20
            guard o + 20 <= b.count else { break }
            let cpu = u32(o)
            if cpu == 0x01000007 { x86 = Int64(u32(o + 12)) }
            if cpu == 0x0100000C { arm = true }
        }
        return x86 > 0 && arm ? x86 : nil
    }

    static func universalBinaries() -> CleanGroup {
        var items: [CleanItem] = []
        for app in AppCatalog.appURLs() {
            guard let exe = FS.bundleInfo(app)?["CFBundleExecutable"] as? String,
                  let s = x86SliceSize(app.appendingPathComponent("Contents/MacOS/\(exe)")), s > 1_000_000 else { continue }
            items.append(CleanItem(url: app, title: FS.displayName(app), subtitle: "Contient aussi le code pour les anciens Mac Intel", size: s, mode: .none, preselected: false, iconPath: app.path))
        }
        return CleanGroup(id: "universal", title: "Code Intel inutile", subtitle: "Partie des apps prévue pour les Mac Intel",
                          symbol: "cpu", items: sorted(items),
                          note: "Analyse seule. Votre Mac a une puce Apple : ce code ne sert jamais. Le retirer casserait la signature des apps, zerOS ne le fait donc pas. Il revient de toute façon à chaque mise à jour.",
                          infoOnly: true)
    }

    // 12. Xcode junk
    static func xcodeJunk() -> CleanGroup {
        let entries: [(String, String, Bool)] = [
            ("Developer/Xcode/DerivedData", "Données de compilation", true),
            ("Developer/CoreSimulator/Caches", "Caches des simulateurs", true),
            ("Developer/Xcode/iOS Device Logs", "Journaux des appareils", true),
            ("Caches/com.apple.dt.Xcode", "Cache Xcode", true),
            ("Developer/Xcode/iOS DeviceSupport", "Fichiers de prise en charge iOS", false),
        ]
        var items: [CleanItem] = []
        for (p, t, pre) in entries {
            let u = FS.lib(p)
            let s = FS.allocatedSize(u)
            if s > 1_000_000 { items.append(CleanItem(url: u, title: t, subtitle: "~/Library/\(p)", size: s, mode: .emptyDir, preselected: pre, symbol: "hammer")) }
        }
        // Archives d'apps : vos versions publiées (indispensables pour lire leurs rapports de plantage), jamais recréées → Corbeille, jamais cochées.
        for a in FS.children(FS.lib("Developer/Xcode/Archives")) where FS.isDir(a) {
            let s = FS.allocatedSize(a)
            if s > 1_000_000 { items.append(CleanItem(url: a, title: "Archives d'apps · \(a.lastPathComponent)", subtitle: "~/Library/Developer/Xcode/Archives", size: s, mode: .trash, preselected: false, symbol: "archivebox")) }
        }
        return CleanGroup(id: "xcode", title: "Déchets Xcode", subtitle: "Fichiers laissés par l'outil de création d'apps",
                          symbol: "hammer", items: sorted(items), regenerable: true)
    }
}

// MARK: - Mail attachments

enum MailJunk {
    static func scan() -> CleanGroup {
        var items: [CleanItem] = []
        for v in FS.children(FS.lib("Mail")) where v.lastPathComponent.hasPrefix("V") {
            // `find` is far faster than FileManager on mailboxes with hundreds of thousands of messages.
            let found = Shell.run("/usr/bin/find", [v.path, "-type", "d", "-name", "Attachments", "-prune"], timeout: 180).out
            let inAttach = found.components(separatedBy: "\n").filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
            for a in inAttach {
                FS.walk(a, keys: [.totalFileAllocatedSizeKey, .contentModificationDateKey], skipPackages: true) { f, val in
                    guard val.isDirectory != true || val.isPackage == true else { return true }
                    let s = val.isPackage == true ? FS.allocatedSize(f) : Int64(val.totalFileAllocatedSize ?? 0)
                    if s > 20_000 { items.append(CleanItem(url: f, title: f.lastPathComponent, subtitle: "Pièce jointe", size: s, date: val.contentModificationDate, mode: .trash, preselected: false, iconPath: f.path)) }
                    return true
                }
            }
        }
        for f in FS.children(FS.lib("Containers/com.apple.mail/Data/Library/Mail Downloads")) {
            items.append(CleanItem(url: f, title: f.lastPathComponent, subtitle: "Téléchargé depuis Mail", size: FS.allocatedSize(f), mode: .trash, preselected: false, iconPath: f.path))
        }
        items.sort { $0.size > $1.size }
        return CleanGroup(id: "mail", title: "Pièces jointes Mail", subtitle: "Copies locales des pièces jointes",
                          symbol: "paperclip", items: Array(items.prefix(3000)),
                          note: "Copies stockées sur le Mac : vos e-mails restent intacts. Rien n'est coché ; elles vont à la Corbeille (une boîte « Sur mon Mac » peut ne pas avoir d'autre copie).")
    }
}

// MARK: - Trash bins

enum TrashBins {
    static var userTrash: URL { FS.h(".Trash") }

    static var userTrashSize: Int64 { FS.allocatedSize(userTrash) }

    /// Une corbeille de l'utilisateur : la sienne (~/.Trash) ou celle d'un disque externe qui lui appartient (.Trashes/<uid>).
    struct Bin: Identifiable, Sendable, Equatable {
        var id: String { url.path }
        let url: URL
        let title: String
        var readable: Bool
        var count: Int
        var size: Int64
        /// Éléments mis à la Corbeille par zerOS depuis moins de 24 h, encore dedans.
        var recent: Int
    }

    /// Relevé des corbeilles (lecture seule, hors fil principal). `volumes` : dossier des disques montés (remplaçable par l'autotest).
    static func bins(user: URL = userTrash, volumes: URL = URL(fileURLWithPath: "/Volumes"), uid: uid_t = getuid()) -> [Bin] {
        func bin(_ u: URL, _ title: String) -> Bin {
            let readable = (try? FileManager.default.contentsOfDirectory(atPath: u.path)) != nil
            return Bin(url: u, title: title, readable: readable, count: readable ? FS.children(u, hidden: true).filter { $0.lastPathComponent != ".DS_Store" }.count : 0,
                       size: FS.allocatedSize(u), recent: TrashLog.recent(in: u))
        }
        var out = [bin(user, "Corbeille")]
        for v in FS.children(volumes) where FS.responds(v) {
            let t = v.appendingPathComponent(".Trashes/\(uid)")
            guard FS.exists(t), let owner = try? FileManager.default.attributesOfItem(atPath: t.path)[.ownerAccountID] as? NSNumber, owner.uint32Value == uid else { continue }
            let b = bin(t, "Corbeille de « \(v.lastPathComponent) »")
            if b.count > 0 { out.append(b) }
        }
        return out
    }

    struct EmptyReport: Sendable { var removed = 0; var freed: Int64 = 0; var left: [String] = [] }

    /// Vide une corbeille de l'utilisateur, élément par élément, sans mot de passe administrateur ni Finder : un élément verrouillé (ou qui
    /// en contient un), protégé (`Ignore.removalBlocker`) ou en cours d'utilisation est laissé en place et signalé.
    static func empty(_ bin: URL) -> EmptyReport {
        var r = EmptyReport()
        let p = bin.standardizedFileURL.path
        guard p == userTrash.standardizedFileURL.path || p.range(of: "^/Volumes/[^/]+/\\.Trashes/\\d+$", options: .regularExpression) != nil || p.hasSuffix("/.Trash")
        else { r.left.append("\(bin.path) : n'est pas une corbeille"); return r }
        for c in FS.children(bin, hidden: true) {
            if c.lastPathComponent == ".DS_Store" { try? FileManager.default.removeItem(at: c); continue }
            if let why = Ignore.removalBlocker(c) { r.left.append("\(c.lastPathComponent) : \(why)"); continue }
            if containsLocked(c) { r.left.append("\(c.lastPathComponent) : verrouillé"); continue }
            let s = FS.allocatedSize(c)
            do { try FileManager.default.removeItem(at: c); r.removed += 1; r.freed += s }
            catch { r.left.append("\(c.lastPathComponent) : en cours d'utilisation ou non supprimable") }
        }
        return r
    }

    /// Verrouillé dans le Finder (« Verrouillé ») ou par le système, lui-même ou un élément qu'il contient.
    static func containsLocked(_ u: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isUserImmutableKey, .isSystemImmutableKey]
        func locked(_ x: URL) -> Bool {
            guard let v = try? x.resourceValues(forKeys: keys) else { return false }
            return v.isUserImmutable == true || v.isSystemImmutable == true
        }
        if locked(u) { return true }
        guard FS.isDir(u), !FS.isSymlink(u), let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { return false }
        for case let f as URL in e where locked(f) { return true }
        return false
    }

    /// Texte de la confirmation : nombre, taille, part mise par zerOS depuis 24 h, irréversible.
    static func confirmation(_ b: Bin) -> String {
        "\(b.title) : \(Fmt.count(b.count, "élément")), \(Fmt.bytes(b.size))"
            + (b.recent > 0 ? ", dont \(Fmt.count(b.recent, "élément mis", "éléments mis")) à la Corbeille par zerOS depuis 24 h." : ".")
            + "\n\nIrréversible : ils seront supprimés définitivement. Les éléments verrouillés ou en cours d'utilisation restent en place."
    }
}

// MARK: - AI clutter

enum AIClutter {
    static let keywords = ["openai", "anthropic", "claude", "chatgpt", "gemini", "copilot", "cursor", "ollama", "lmstudio", "lm-studio",
                           "perplexity", "diffusionbee", "huggingface", "whisper", "gpt4all", "pinokio", "comfyui", "msty", "jan.ai", "codex", "mistral", "poe"]
    static let dotCacheAI: Set<String> = ["huggingface", "torch", "lm-studio", "whisper", "gpt4all"]
    static let electronCaches = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "Service Worker/CacheStorage", "Crashpad/completed"]

    static func isAIName(_ n: String) -> Bool {
        let l = n.lowercased()
        return keywords.contains { k in l.contains(k) } && !l.hasPrefix("com.apple.")
    }

    static func scan() -> [CleanGroup] {
        let running = Junk.runningIDs
        let runningNames = Set(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName?.lowercased() })
        var caches: [CleanItem] = [], logs: [CleanItem] = [], models: [CleanItem] = []

        for d in FS.children(FS.lib("Caches")) where isAIName(d.lastPathComponent) {
            let s = FS.allocatedSize(d); guard s > 100_000 else { continue }
            let id = d.lastPathComponent
            let app = FS.appURL(forBundleID: id)
            let open = Junk.belongsToRunningApp(id, ids: running)
            caches.append(CleanItem(url: d, title: app.map(FS.displayName) ?? id, subtitle: open ? "App ouverte — décoché" : "Cache", size: s,
                                    mode: FS.isDir(d) ? .emptyDir : .delete, preselected: !open, iconPath: app?.path))
        }
        // Electron-based AI apps keep caches in Application Support.
        for d in FS.children(FS.lib("Application Support")) where isAIName(d.lastPathComponent) {
            let open = runningNames.contains(d.lastPathComponent.lowercased())
            for sub in electronCaches {
                let u = d.appendingPathComponent(sub)
                let s = FS.allocatedSize(u); guard s > 500_000 else { continue }
                caches.append(CleanItem(url: u, title: "\(d.lastPathComponent) — \(sub)", subtitle: open ? "App ouverte — décoché" : "Cache de l'interface",
                                        size: s, mode: .emptyDir, preselected: !open, symbol: "brain"))
            }
        }
        for d in FS.children(FS.lib("Logs")) where isAIName(d.lastPathComponent) {
            let s = FS.allocatedSize(d); guard s > 20_000 else { continue }
            logs.append(CleanItem(url: d, title: d.lastPathComponent, subtitle: "Journaux", size: s, mode: FS.isDir(d) ? .emptyDir : .delete, symbol: "doc.text"))
        }
        for p in [".codex/log", ".ollama/logs", ".cursor/logs"] {
            let u = FS.h(p); let s = FS.allocatedSize(u)
            if s > 20_000 { logs.append(CleanItem(url: u, title: "~/\(p)", subtitle: "Journaux", size: s, mode: .emptyDir, symbol: "doc.text")) }
        }
        let modelDirs: [(String, String)] = [
            (".ollama/models", "Modèles Ollama"), (".lmstudio/models", "Modèles LM Studio"), (".cache/lm-studio", "LM Studio"),
            (".cache/huggingface", "Modèles Hugging Face"), (".cache/torch", "Modèles PyTorch"), (".cache/whisper", "Modèles Whisper"),
            (".cache/gpt4all", "GPT4All"), ("Library/Application Support/DiffusionBee", "DiffusionBee"), (".diffusionbee", "DiffusionBee"),
            ("Library/Application Support/nomic.ai/GPT4All", "GPT4All"), ("Library/Application Support/Jan", "Jan"), ("pinokio", "Pinokio"),
        ]
        for (p, t) in modelDirs {
            let u = FS.h(p); let s = FS.allocatedSize(u)
            if s > 10_000_000 { models.append(CleanItem(url: u, title: t, subtitle: "~/\(p)", size: s, mode: .trash, preselected: false, symbol: "cpu")) }
        }
        return [
            CleanGroup(id: "aiCaches", title: "IA — caches", subtitle: "ChatGPT, Claude, Gemini, Cursor…", symbol: "brain", items: Junk.sorted(caches),
                       note: "Fichiers temporaires des apps d'IA. Vos conversations et réglages ne sont jamais touchés.", regenerable: true),
            CleanGroup(id: "aiLogs", title: "IA — journaux", subtitle: "Historique technique des outils d'IA", symbol: "doc.text.magnifyingglass", items: Junk.sorted(logs), regenerable: true),
            CleanGroup(id: "aiModels", title: "IA — modèles locaux", subtitle: "Modèles téléchargés sur le Mac", symbol: "cpu", items: Junk.sorted(models),
                       note: "Ces modèles sont gros mais peut-être utiles : rien n'est coché. Ils partent à la Corbeille si vous les sélectionnez."),
        ].filter { !$0.items.isEmpty }
    }
}
