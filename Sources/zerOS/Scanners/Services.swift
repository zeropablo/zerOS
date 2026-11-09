import Foundation

/// Services d'arrière-plan (LaunchAgents / LaunchDaemons) liés à une app, ou orphelins. Lecture seule ici :
/// la suppression passe par `AppCatalog.uninstall` (bootout puis Corbeille, toujours via `Ignore.removalBlocker`).
struct LinkedService: Identifiable {
    var id: String { item.id }
    let item: BackgroundItem
    /// Pourquoi il est rattaché : identifiant, éditeur, Team ID.
    let reasons: [String]
    /// Une autre app installée du même éditeur s'en sert aussi (ex. Google Keystone pour Chrome et Google Earth) : décoché par défaut.
    let sharedWith: String?
}

enum Services {
    /// Team ID de la signature d'un exécutable ou d'une app (nil si absente, ou signature Apple « not set »).
    static func teamID(ofProgram path: String, cache: inout [String: String?]) -> String? {
        if let c = cache[path] { return c }
        let t = Updater.teamID(URL(fileURLWithPath: path))
        cache[path] = .some(t)
        return t
    }

    /// « com.google.Chrome » → « com.google ».
    static func publisherPrefix(_ bundleID: String) -> String? {
        let p = bundleID.split(separator: ".")
        return p.count >= 3 ? p.prefix(2).joined(separator: ".") : nil
    }

    static func isSystemProgram(_ path: String) -> Bool {
        ["/System/", "/usr/", "/bin/", "/sbin/"].contains { path.hasPrefix($0) }
    }

    /// Services rattachés à `app` par identifiant, éditeur et Team ID. Les apps Apple n'ont jamais de service rattaché.
    static func linked(to app: AppInfo, items: [BackgroundItem]? = nil, teamCache: inout [String: String?]) -> [LinkedService] {
        if let id = app.bundleID, id.hasPrefix("com.apple.") { return [] }
        let items = items ?? BackgroundItems.list()
        let appTeam = Updater.teamID(app.url)
        let prefix = app.bundleID.flatMap(publisherPrefix)
        var siblings: [(name: String, team: String?)]?   // calculé seulement si utile
        var out: [LinkedService] = []
        for i in items where !i.label.hasPrefix("com.apple.") {
            var why: [String] = []
            var byID = false
            if let id = app.bundleID, i.label == id || i.label.hasPrefix(id + ".") { why.append("identifiant \(id)"); byID = true }
            if !i.program.isEmpty, i.program.hasPrefix(app.url.path + "/") { why.append("programme dans l'app"); byID = true }
            if !byID, let team = appTeam, !i.program.isEmpty, !isSystemProgram(i.program), FileManager.default.fileExists(atPath: i.program),
               teamID(ofProgram: i.program, cache: &teamCache) == team {
                if let prefix, i.label.hasPrefix(prefix + ".") { why.append("éditeur \(prefix)") }
                why.append("Team ID \(team)")
            }
            guard !why.isEmpty else { continue }
            var shared: String?
            if !byID, let prefix, let team = appTeam {
                if siblings == nil {
                    siblings = AppCatalog.appURLs().filter { $0 != app.url }.compactMap { u in
                        guard let id = FS.bundleInfo(u)?["CFBundleIdentifier"] as? String, id.hasPrefix(prefix + ".") else { return nil }
                        return (FS.displayName(u), Updater.teamID(u))
                    }
                }
                shared = siblings?.first { $0.team == team }?.name
            }
            out.append(LinkedService(item: i, reasons: why, sharedWith: shared))
        }
        return out
    }

    /// Services dont l'exécutable n'existe plus (app supprimée). Un programme sur un volume débranché n'est pas un orphelin.
    static func orphans(items: [BackgroundItem]? = nil) -> [(item: BackgroundItem, why: String)] {
        (items ?? BackgroundItems.list()).compactMap { i in
            guard !i.label.hasPrefix("com.apple."), i.program.hasPrefix("/"), !i.program.hasPrefix("/Volumes/") else { return nil }
            guard !FileManager.default.fileExists(atPath: i.program) else { return nil }
            return (i, "programme introuvable : \(i.program.replacingOccurrences(of: FS.home.path, with: "~"))")
        }
    }

    /// Éditeur et Team ID d'une app installée (pour `probableOrphans`).
    struct Owner: Sendable { var prefix: String?; var team: String? }

    static func installedOwners() -> [Owner] {
        let urls = AppCatalog.appURLs()
        var out = [Owner](repeating: Owner(), count: urls.count)
        // codesign par app : en parallèle, sinon plusieurs secondes.
        out.withUnsafeMutableBufferPointer { buf in
            let b = buf
            DispatchQueue.concurrentPerform(iterations: urls.count) { k in
                let id = FS.bundleInfo(urls[k])?["CFBundleIdentifier"] as? String
                b[k] = Owner(prefix: id.flatMap(publisherPrefix), team: Updater.teamID(urls[k]))
            }
        }
        return out
    }

    /// 2e règle : le programme existe mais aucune app installée n'a le même éditeur (préfixe de l'identifiant) ni le même
    /// Team ID (ex. Google Keystone, dont le programme est dans ~/Library/Google et non dans une app). Seulement pour un programme
    /// signé par un développeur : sans Team ID (Homebrew, outils maison), impossible de savoir, rien n'est signalé.
    static func probableOrphans(items: [BackgroundItem]? = nil, owners: [Owner]? = nil,
                                teamOf: (String) -> String? = { Updater.teamID(URL(fileURLWithPath: $0)) }) -> [(item: BackgroundItem, why: String)] {
        let appRoots = ["/Applications/", FS.h("Applications").path + "/"]
        let candidates = (items ?? BackgroundItems.list()).filter { i in
            !i.label.hasPrefix("com.apple.") && i.program.hasPrefix("/") && !i.program.hasPrefix("/Volumes/") && !isSystemProgram(i.program)
                && !appRoots.contains { i.program.hasPrefix($0) } && FileManager.default.fileExists(atPath: i.program)
        }
        guard !candidates.isEmpty else { return [] }
        let owners = owners ?? installedOwners()
        let prefixes = Set(owners.compactMap(\.prefix)), teams = Set(owners.compactMap(\.team))
        return candidates.compactMap { i in
            let prefix = publisherPrefix(i.label)
            if let prefix, prefixes.contains(prefix) { return nil }
            guard let team = teamOf(i.program), !teams.contains(team) else { return nil }
            return (i, "orphelin probable : aucune app installée de l'éditeur \(prefix ?? "?") ni du Team ID \(team) · programme : \(i.program.replacingOccurrences(of: FS.home.path, with: "~"))")
        }
    }

    /// `launchctl bootout` d'un service de session (agent). Refusé si le fichier est protégé. Les démons système sont arrêtés
    /// dans la commande administrateur de la désinstallation (`bootoutCommand`).
    @discardableResult
    static func stop(plist: URL) -> Bool {
        guard Ignore.removalBlocker(plist) == nil, plist.deletingLastPathComponent().lastPathComponent != "LaunchDaemons",
              let label = label(of: plist) else { return false }
        return Shell.sh("/bin/launchctl bootout gui/\(getuid())/\(Shell.q(label)) 2>/dev/null; true").ok
    }

    static func bootoutCommand(plist: URL) -> String? {
        guard plist.deletingLastPathComponent().lastPathComponent == "LaunchDaemons", let label = label(of: plist) else { return nil }
        return "launchctl bootout system/\(Shell.q(label)) 2>/dev/null"
    }

    static func isServicePlist(_ u: URL) -> Bool {
        u.pathExtension == "plist" && ["LaunchAgents", "LaunchDaemons"].contains(u.deletingLastPathComponent().lastPathComponent)
    }

    static func label(of plist: URL) -> String? {
        (FS.plist(plist)?["Label"] as? String) ?? plist.deletingPathExtension().lastPathComponent
    }
}
