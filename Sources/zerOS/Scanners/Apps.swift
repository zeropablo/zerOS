import Foundation
import AppKit

struct AppInfo: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let bundleID: String?
    let version: String
    let build: String
    var size: Int64
    let lastUsed: Date?
    let isAppStore: Bool
    let isApple: Bool
    let feedURL: String?
}

enum AppCatalog {
    static let excluded: Set<String> = ["com.apple.Safari", "com.zeropablo.zeros"]

    static func appURLs() -> [URL] {
        var out: [URL] = []
        for root in [URL(fileURLWithPath: "/Applications"), FS.h("Applications")] {
            for c in FS.children(root) {
                if c.pathExtension == "app" { out.append(c) }
                else if FS.isDir(c) && !FS.isSymlink(c) {
                    out += FS.children(c).filter { $0.pathExtension == "app" }
                }
            }
        }
        return out
    }

    static func lastUsed(_ u: URL) -> Date? {
        NSMetadataItem(url: u)?.value(forAttribute: "kMDItemLastUsedDate") as? Date
    }

    static func info(_ u: URL, withSize: Bool) -> AppInfo? {
        let i = FS.bundleInfo(u) ?? [:]
        let id = i["CFBundleIdentifier"] as? String
        if let id, excluded.contains(id) { return nil }
        return AppInfo(url: u, name: FS.displayName(u), bundleID: id,
                       version: i["CFBundleShortVersionString"] as? String ?? "",
                       build: i["CFBundleVersion"] as? String ?? "",
                       size: withSize ? FS.allocatedSize(u) : 0,
                       lastUsed: lastUsed(u),
                       isAppStore: FS.exists(u.appendingPathComponent("Contents/_MASReceipt/receipt")),
                       isApple: id?.hasPrefix("com.apple.") ?? false,
                       feedURL: i["SUFeedURL"] as? String)
    }

    static func list(_ rep: Reporter = .silent) -> [AppInfo] {
        let urls = appURLs()
        var out: [AppInfo] = []
        for (n, u) in urls.enumerated() {
            rep.tick("Analyse des apps \(n + 1)/\(urls.count)…")
            if let a = info(u, withSize: true) { out.append(a) }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Every bundle ID installed anywhere (apps, helpers, system apps).
    static func installedBundleIDs() -> Set<String> {
        var ids = Set<String>()
        let r = Shell.run("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle'"], timeout: 60)
        var paths = r.out.components(separatedBy: "\n").filter { !$0.isEmpty }
        paths += appURLs().map(\.path)
        for p in Set(paths) {
            if let id = FS.bundleInfo(URL(fileURLWithPath: p))?["CFBundleIdentifier"] as? String { ids.insert(id) }
        }
        return ids
    }

    // MARK: Related files

    static let userDirs = ["Application Support", "Caches", "Containers", "Group Containers", "Saved Application State", "Logs", "HTTPStorages",
                           "WebKit", "Cookies", "Application Scripts", "Preferences", "Preferences/ByHost", "LaunchAgents"]

    static func matches(_ name: String, bundleID: String?, appName: String, dir: String) -> Bool {
        if let id = bundleID {
            if name == id || name.hasPrefix(id + ".") { return true }
            if dir == "Group Containers" && name.hasSuffix("." + id) { return true }
        }
        if ["Application Support", "Caches", "Logs"].contains(dir) && name.caseInsensitiveCompare(appName) == .orderedSame { return true }
        return false
    }

    static func relatedFiles(for app: AppInfo) -> [CleanItem] {
        var out: [CleanItem] = []
        guard !(app.bundleID ?? "").isEmpty || !app.name.isEmpty else { return out }
        for dir in userDirs {
            for c in FS.children(FS.lib(dir), hidden: true) where matches(c.lastPathComponent, bundleID: app.bundleID, appName: app.name, dir: dir) {
                if c.lastPathComponent.hasPrefix("com.apple.") && c.lastPathComponent != app.bundleID { continue }
                out.append(CleanItem(url: c, title: c.lastPathComponent, subtitle: "~/Library/\(dir)", size: FS.allocatedSize(c), mode: .trash,
                                     preselected: regenerableDirs.contains(dir), iconPath: nil, symbol: symbol(dir)))
            }
        }
        for dir in ["Application Support", "LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools", "Caches"] {
            for c in FS.children(URL(fileURLWithPath: "/Library/\(dir)")) where matches(c.lastPathComponent, bundleID: app.bundleID, appName: app.name, dir: dir == "PrivilegedHelperTools" ? "Caches" : dir) {
                out.append(CleanItem(url: c, title: c.lastPathComponent, subtitle: "/Library/\(dir)", size: FS.allocatedSize(c), mode: .adminTrash,
                                     preselected: dir == "Caches", symbol: symbol(dir)))
            }
        }
        // Services d'arrière-plan trouvés par éditeur / Team ID (ceux trouvés par identifiant sont déjà ci-dessus).
        var cache: [String: String?] = [:]
        for l in Services.linked(to: app, teamCache: &cache) where !out.contains(where: { $0.url == l.item.plist }) {
            out.append(CleanItem(url: l.item.plist, title: l.item.label,
                                 subtitle: "Service d'arrière-plan · " + l.reasons.joined(separator: ", ") + (l.sharedWith.map { " · partagé avec \($0)" } ?? ""),
                                 size: FS.allocatedSize(l.item.plist), mode: l.item.scope == .user ? .trash : .adminTrash,
                                 preselected: false, symbol: "bolt.horizontal"))
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Dossiers dont le contenu se recrée seul (caches, état des fenêtres, journaux) : seuls fichiers liés cochés d'office à la désinstallation.
    /// Tout va de toute façon à la Corbeille.
    static let regenerableDirs: Set<String> = ["Caches", "Saved Application State", "Logs", "HTTPStorages", "WebKit"]

    static func symbol(_ dir: String) -> String {
        switch dir {
        case "Caches": return "shippingbox"
        case "Preferences", "Preferences/ByHost": return "slider.horizontal.3"
        case "Logs": return "doc.text"
        case "LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools": return "bolt.horizontal"
        case "Containers", "Group Containers": return "archivebox"
        default: return "folder"
        }
    }

    // MARK: Uninstall

    static func quit(_ app: AppInfo) {
        guard let id = app.bundleID else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        running.forEach { $0.terminate() }
        var n = 0
        while running.contains(where: { !$0.isTerminated }) && n < 20 { Thread.sleep(forTimeInterval: 0.25); n += 1 }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    /// Moves the app and the chosen files to the Trash. `keepApp` = reset only.
    static func uninstall(_ app: AppInfo, files: [CleanItem], keepApp: Bool) -> CleanReport {
        var r = CleanReport()
        if !keepApp, let why = Ignore.removalBlocker(app.url) {
            r.errors.append("L'app \(app.name) : \(why), rien n'a été supprimé.")
            return r
        }
        quit(app)
        // Services d'abord arrêtés (bootout), ensuite seulement mis à la Corbeille ; un fichier protégé n'est pas touché.
        for f in files { if let u = f.url, Services.isServicePlist(u) { Services.stop(plist: u) } }
        if !keepApp {
            do { try FS.trash(app.url); r.freed += app.size; r.count += 1 }
            catch {
                // Finder fallback only for apps the guards accept (checked above): never a way around them.
                let esc = app.url.path.replacingOccurrences(of: "\"", with: "\\\"")
                let f = Shell.osa("tell application \"Finder\" to delete (POSIX file \"\(esc)\")")
                if f.ok { r.freed += app.size; r.count += 1 } else { r.errors.append("L'app \(app.name) n'a pas pu être supprimée.") }
            }
        }
        let plan = adminPlan(files)
        r.errors += plan.refused
        for f in files where f.mode != .adminTrash {
            guard let u = f.url else { continue }
            do { try FS.trash(u); r.freed += f.size; r.count += 1 } catch { r.errors.append("\(f.title) : \(error.localizedDescription)") }
        }
        if !plan.items.isEmpty {
            let cmd = plan.items.compactMap(\.url).map { u in
                [Services.bootoutCommand(plist: u), FS.adminTrashCommand(u)].compactMap { $0 }.joined(separator: " ; ")
            }.joined(separator: " ; ")
            if Shell.admin(cmd).ok {
                r.count += plan.items.count
                r.freed += plan.items.reduce(0) { $0 + $1.size }
            } else { r.errors.append("Fichiers système de l'app non mis à la Corbeille (mot de passe annulé).") }
        }
        return r
    }

    /// System files removed with the admin password: each one goes through `Ignore.removalBlocker` first,
    /// refused ones are listed and never reach `rm`.
    static func adminPlan(_ files: [CleanItem]) -> (items: [CleanItem], refused: [String]) {
        var items: [CleanItem] = [], refused: [String] = []
        for f in files where f.mode == .adminTrash {
            guard let u = f.url else { continue }
            if let why = Ignore.removalBlocker(u) { refused.append("\(f.title) : \(why)") } else { items.append(f) }
        }
        return (items, refused)
    }

    // MARK: Leftovers of apps already deleted

    static let bundleRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9-]+\\.[A-Za-z0-9-]+\\.[A-Za-z0-9.\\-_]+$")
    static let leftoverDirs = ["Application Support", "Caches", "Containers", "Saved Application State", "Preferences", "HTTPStorages", "WebKit", "Logs", "LaunchAgents", "Application Scripts"]
    static let neverFlag = ["com.apple.", "group.com.apple.", "com.zeropablo.", "systemgroup."]

    static func leftovers(_ rep: Reporter, onlyBundleID: String? = nil) async -> [CleanGroup] {
        rep("Recensement des apps installées…")
        let installed = installedBundleIDs()
        let vendors = Set(installed.map { $0.split(separator: ".").prefix(2).joined(separator: ".").lowercased() })
        var groups: [CleanGroup] = []
        for dir in leftoverDirs {
            rep("Recherche des restes dans \(dir)…")
            var items: [CleanItem] = []
            for c in FS.children(FS.lib(dir), hidden: false) {
                var n = c.lastPathComponent
                for ext in ["plist", "savedState", "binarycookies"] where n.hasSuffix("." + ext) { n = String(n.dropLast(ext.count + 1)) }
                if dir == "Preferences", n.hasSuffix(".plist") { continue }
                guard bundleRegex.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil else { continue }
                if neverFlag.contains(where: { n.lowercased().hasPrefix($0) }) { continue }
                if let only = onlyBundleID, n != only && !n.hasPrefix(only + ".") { continue }
                if installed.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame || n.lowercased().hasPrefix($0.lowercased() + ".") || $0.lowercased().hasPrefix(n.lowercased() + ".") }) { continue }
                let vendor = n.split(separator: ".").prefix(2).joined(separator: ".").lowercased()
                let sameVendor = vendors.contains(vendor)
                let s = FS.allocatedSize(c)
                items.append(CleanItem(url: c, title: n, subtitle: sameVendor ? "Éditeur encore présent sur le Mac — à vérifier" : "App introuvable sur le Mac",
                                       size: s, mode: .trash, preselected: !sameVendor || onlyBundleID != nil, symbol: symbol(dir)))
            }
            if !items.isEmpty {
                groups.append(CleanGroup(id: "left.\(dir)", title: title(dir), subtitle: "~/Library/\(dir)", symbol: symbol(dir), items: items.sorted { $0.size > $1.size },
                                         note: "Fichiers laissés par des apps qui ne sont plus installées. Ils vont à la Corbeille, vous pouvez donc changer d'avis."))
            }
        }
        return groups
    }

    static func title(_ dir: String) -> String {
        switch dir {
        case "Application Support": return "Données d'apps supprimées"
        case "Caches": return "Caches d'apps supprimées"
        case "Containers": return "Conteneurs orphelins"
        case "Saved Application State": return "États de fenêtres"
        case "Preferences": return "Réglages orphelins"
        case "HTTPStorages", "WebKit": return "Données web (\(dir))"
        case "Logs": return "Journaux orphelins"
        case "LaunchAgents": return "Lanceurs orphelins"
        default: return dir
        }
    }

    // MARK: Installers

    static func installers(_ rep: Reporter) async -> [CleanGroup] {
        rep("Recherche des fichiers d'installation…")
        var items: [CleanItem] = []
        let exts: Set<String> = ["dmg", "pkg", "mpkg", "xip"]
        for root in [FS.h("Downloads"), FS.h("Desktop"), FS.h("Documents")] {
            FS.walk(root, keys: [.totalFileAllocatedSizeKey, .addedToDirectoryDateKey, .contentModificationDateKey], skipPackages: true, exclude: Clutter.excludedFromHome) { f, v in
                guard exts.contains(f.pathExtension.lowercased()) else { return true }
                let d = v.addedToDirectoryDate ?? v.contentModificationDate
                let s = v.isPackage == true ? FS.allocatedSize(f) : Int64(v.totalFileAllocatedSize ?? 0)
                items.append(CleanItem(url: f, title: f.lastPathComponent, subtitle: f.deletingLastPathComponent().path.replacingOccurrences(of: FS.home.path, with: "~"),
                                       size: s, date: d, mode: .trash, preselected: false, iconPath: f.path))
                return true
            }
        }
        return [CleanGroup(id: "installers", title: "Fichiers d'installation", subtitle: "Images disque (.dmg) et paquets (.pkg) déjà utilisés",
                           symbol: "shippingbox.and.arrow.backward", items: items.sorted { $0.size > $1.size },
                           note: "Une fois l'app installée, ces fichiers ne servent plus. Ceux de moins d'une semaine sont décochés.")].filter { !$0.items.isEmpty }
    }
}

// MARK: - Updater

struct AppUpdate: Identifiable, Hashable {
    enum Source: Hashable { case sparkle(download: String), brew(token: String), appStore }
    var id: String { appName + latest }
    let appName: String
    let appURL: URL?
    let current: String
    let latest: String
    let source: Source
    let notes: String?
}

final class AppcastParser: NSObject, XMLParserDelegate {
    struct Entry { var short = ""; var build = ""; var url = ""; var channel = ""; var minOS = "" }
    var entries: [Entry] = []
    private var cur: Entry?
    private var text = ""

    func parse(_ data: Data) -> [Entry] {
        let p = XMLParser(data: data)
        p.delegate = self
        p.shouldProcessNamespaces = false
        p.parse()
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
        text = ""
        if el == "item" { cur = Entry() }
        if el == "enclosure", cur != nil {
            if let v = a["sparkle:shortVersionString"] { cur?.short = v }
            if let v = a["sparkle:version"] { cur?.build = v }
            if let v = a["url"] { cur?.url = v }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName q: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch el {
        case "sparkle:shortVersionString": cur?.short = t
        case "sparkle:version": cur?.build = t
        case "sparkle:channel": cur?.channel = t
        case "sparkle:minimumSystemVersion": cur?.minOS = t
        case "item": if let c = cur { entries.append(c) }; cur = nil
        default: break
        }
        text = ""
    }
}

enum Updater {
    static func newer(_ a: String, than b: String) -> Bool {
        !a.isEmpty && !b.isEmpty && a.compare(b, options: .numeric) == .orderedDescending
    }

    static func check(_ rep: Reporter) async -> [AppUpdate] {
        let apps = AppCatalog.appURLs().compactMap { AppCatalog.info($0, withSize: false) }
        var updates: [AppUpdate] = []

        if let brew = Shell.brew {
            rep("Vérification Homebrew…")
            let r = Shell.run(brew, ["outdated", "--cask", "--greedy", "--json=v2"], timeout: 120)
            if let d = r.out.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let casks = j["casks"] as? [[String: Any]] {
                for c in casks {
                    let token = c["name"] as? String ?? ""
                    let cur = (c["installed_versions"] as? [String])?.first ?? ""
                    let latest = c["current_version"] as? String ?? ""
                    updates.append(AppUpdate(appName: token, appURL: nil, current: cur, latest: latest, source: .brew(token: token), notes: "Homebrew"))
                }
            }
        }

        let sparkleApps = apps.filter { $0.feedURL != nil && !$0.isAppStore }
        rep("Vérification de \(sparkleApps.count) apps…")
        let found = await withTaskGroup(of: AppUpdate?.self) { g -> [AppUpdate] in
            for a in sparkleApps { g.addTask { await sparkle(a) } }
            var out: [AppUpdate] = []
            for await u in g { if let u { out.append(u) } }
            return out
        }
        for u in found where !updates.contains(where: { $0.appName.caseInsensitiveCompare(u.appName) == .orderedSame }) { updates.append(u) }
        return updates.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    static func sparkle(_ a: AppInfo) async -> AppUpdate? {
        guard let s = a.feedURL, let url = URL(string: s), url.scheme == "https" else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("zerOS", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let entries = AppcastParser().parse(data).filter { $0.channel.isEmpty && ($0.minOS.isEmpty || !newer($0.minOS, than: osString)) && !$0.url.isEmpty }
        guard let best = entries.max(by: { ($0.build.isEmpty ? $0.short : $0.build).compare($1.build.isEmpty ? $1.short : $1.build, options: .numeric) == .orderedAscending }) else { return nil }
        let isNewer: Bool
        if !best.build.isEmpty && !a.build.isEmpty { isNewer = newer(best.build, than: a.build) && (best.short.isEmpty || best.short != a.version) }
        else { isNewer = newer(best.short, than: a.version) }
        guard isNewer else { return nil }
        return AppUpdate(appName: a.name, appURL: a.url, current: a.version, latest: best.short.isEmpty ? best.build : best.short,
                         source: .sparkle(download: best.url), notes: nil)
    }

    static func teamID(_ app: URL) -> String? {
        let r = Shell.run("/usr/bin/codesign", ["-dv", app.path])
        for l in (r.err + r.out).components(separatedBy: "\n") where l.hasPrefix("TeamIdentifier=") {
            let t = String(l.dropFirst("TeamIdentifier=".count))
            return t == "not set" ? nil : t
        }
        return nil
    }

    /// Downloads, checks the developer signature matches, then replaces the app.
    static func install(_ u: AppUpdate, rep: Reporter) async -> String? {
        switch u.source {
        case .appStore:
            NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
            return nil
        case .brew(let token):
            guard let brew = Shell.brew else { return "Homebrew introuvable" }
            rep("Mise à jour de \(token) avec Homebrew…")
            let r = Shell.run(brew, ["upgrade", "--cask", token], timeout: 1200)
            return r.ok ? nil : "Homebrew a besoin du Terminal pour cette app (mot de passe). Lancez : brew upgrade --cask \(token)"
        case .sparkle(let dl):
            guard let appURL = u.appURL, let remote = URL(string: dl) else { return "Lien de téléchargement invalide" }
            rep("Téléchargement de \(u.appName) \(u.latest)…")
            guard let (tmp, _) = try? await URLSession.shared.download(from: remote) else { return "Téléchargement impossible" }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("zeros-update-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let ext = remote.pathExtension.lowercased()
            let archive = work.appendingPathComponent("download." + (ext.isEmpty ? "zip" : ext))
            try? FileManager.default.moveItem(at: tmp, to: archive)
            var newApp: URL?
            var mount: String?
            rep("Préparation…")
            if ext == "dmg" {
                let r = Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-plist", archive.path])
                if let d = r.out.data(using: .utf8), let pl = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
                   let ents = pl["system-entities"] as? [[String: Any]] {
                    mount = ents.compactMap { $0["mount-point"] as? String }.first
                }
                if let m = mount { newApp = FS.children(URL(fileURLWithPath: m)).first { $0.pathExtension == "app" } }
            } else if ext == "zip" || ext.isEmpty {
                Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, work.appendingPathComponent("x").path])
                newApp = FS.children(work.appendingPathComponent("x")).first { $0.pathExtension == "app" }
            } else {
                NSWorkspace.shared.open(remote)
                return "Format \(ext) : le téléchargement a été ouvert dans votre navigateur."
            }
            defer { if let m = mount { Shell.run("/usr/bin/hdiutil", ["detach", m, "-quiet"]) } }
            guard let newApp else { return "L'app n'a pas été trouvée dans le téléchargement" }
            guard let oldTeam = teamID(appURL), oldTeam == teamID(newApp) else {
                return "Signature du développeur différente : mise à jour bloquée par sécurité."
            }
            if let why = Ignore.removalBlocker(appURL) { return "Mise à jour impossible : \(why)." }
            rep("Installation de \(u.appName)…")
            if let id = FS.bundleInfo(appURL)?["CFBundleIdentifier"] as? String,
               let info = AppCatalog.info(appURL, withSize: false), id == info.bundleID { AppCatalog.quit(info) }
            let staged = appURL.deletingLastPathComponent().appendingPathComponent(".\(appURL.lastPathComponent).new")
            try? FileManager.default.removeItem(at: staged)
            let copy = Shell.run("/usr/bin/ditto", [newApp.path, staged.path])
            if copy.ok, (try? FS.trash(appURL)) != nil, (try? FileManager.default.moveItem(at: staged, to: appURL)) != nil {
                return nil
            }
            try? FileManager.default.removeItem(at: staged)
            // Ancienne version à la Corbeille (récupérable), jamais supprimée.
            let cmd = "ditto \(Shell.q(newApp.path)) \(Shell.q(staged.path)) && \(FS.adminTrashCommand(appURL)) && mv \(Shell.q(staged.path)) \(Shell.q(appURL.path))"
            return Shell.admin(cmd).ok ? nil : "Installation annulée."
        }
    }

    static func macOSUpdates() -> [String] {
        let r = Shell.run("/usr/sbin/softwareupdate", ["-l"], timeout: 180)
        return (r.out + r.err).components(separatedBy: "\n").compactMap { l in
            guard let r = l.range(of: "Title: ") else { return nil }
            return String(l[r.upperBound...]).components(separatedBy: ",").first
        }
    }
}
