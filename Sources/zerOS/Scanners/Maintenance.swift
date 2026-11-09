import Foundation
import AppKit

// MARK: - Maintenance tasks

struct MaintenanceTask: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let admin: Bool
    let command: String?      // admin shell command
}

/// Manual repairs only: none is recommended automatically (on Apple Silicon, macOS keeps memory, caches,
/// purgeable space and Mail's index in shape by itself). Time Machine snapshots: see `Snapshots`.
enum Maintenance {
    static let all: [MaintenanceTask] = [
        MaintenanceTask(id: "dns", title: "Vider le cache DNS", detail: "Règle les sites qui ne s'ouvrent plus ou une connexion lente après un changement de réseau.",
                        symbol: "network", admin: true, command: "dscacheutil -flushcache; killall -HUP mDNSResponder"),
        MaintenanceTask(id: "spotlight", title: "Réindexer Spotlight", detail: "Reconstruit la recherche du Mac si elle est lente ou ne trouve plus vos fichiers. Le Mac peut ralentir pendant quelques heures.",
                        symbol: "magnifyingglass", admin: true, command: "mdutil -E /"),
        MaintenanceTask(id: "perms", title: "Réparer les autorisations", detail: "Remet en ordre les droits d'accès de votre dossier personnel. Utile si des apps refusent d'ouvrir des fichiers.",
                        symbol: "lock.rotation", admin: true, command: "diskutil resetUserPermissions / \(getuid())"),
    ]

    /// Runs several tasks with a single password prompt. Returns per-task success and a message.
    static func run(_ tasks: [MaintenanceTask], rep: Reporter) -> (done: [String], freed: Int64, errors: [String]) {
        var done: [String] = [], errors: [String] = []
        let before = FS.volumeFree
        let adminTasks = tasks.filter { $0.admin && $0.command != nil }
        if !adminTasks.isEmpty {
            rep("En attente du mot de passe administrateur…")
            let script = adminTasks.map { "(\($0.command!)) >/dev/null 2>&1" }.joined(separator: " ; ") + " ; true"
            let r = Shell.admin(script, timeout: 1800)
            if r.ok { done += adminTasks.map(\.id) } else { errors.append("Tâches système annulées (mot de passe refusé ou annulé).") }
        }
        let freed = max(0, FS.volumeFree - before)
        return (done, freed, errors)
    }
}

// MARK: - Time Machine local snapshots

struct LocalSnapshot: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let date: Date?
}

enum Snapshots {
    static func list() -> [LocalSnapshot] {
        let out = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).out
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return out.components(separatedBy: "\n").compactMap { l in
            guard let r = l.range(of: "com.apple.TimeMachine.") else { return nil }
            let stamp = l[r.upperBound...].replacingOccurrences(of: ".local", with: "")
            return LocalSnapshot(name: stamp, date: f.date(from: stamp))
        }
    }

    static func delete(_ s: [LocalSnapshot]) -> Bool {
        guard !s.isEmpty else { return true }
        return Shell.admin(s.map { "tmutil deletelocalsnapshots \(Shell.q($0.name))" }.joined(separator: " ; ")).ok
    }
}

// MARK: - Login items (apps opened at login)

struct LoginItem: Identifiable, Hashable, Codable {
    var id: String { name }
    let name: String
    let path: String
    var enabled: Bool
}

enum LoginItems {
    static let disabledKey = "disabledLoginItems"   // [name: path] kept so they can be turned back on

    static func list() -> [LoginItem] {
        let r = Shell.jxa("""
        var se = Application('System Events'); var out = [];
        se.loginItems().forEach(function(i){ out.push({name: i.name(), path: i.path()}); });
        JSON.stringify(out);
        """)
        var items: [LoginItem] = []
        if let d = r.out.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            items = arr.compactMap { o in
                guard let n = o["name"] as? String else { return nil }
                return LoginItem(name: n, path: o["path"] as? String ?? "", enabled: true)
            }
        }
        let disabled = UserDefaults.standard.dictionary(forKey: disabledKey) as? [String: String] ?? [:]
        for (n, p) in disabled where !items.contains(where: { $0.name == n }) {
            items.append(LoginItem(name: n, path: p, enabled: false))
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func setEnabled(_ item: LoginItem, _ on: Bool) -> Bool {
        var disabled = UserDefaults.standard.dictionary(forKey: disabledKey) as? [String: String] ?? [:]
        let name = item.name.replacingOccurrences(of: "\"", with: "\\\"")
        let path = item.path.replacingOccurrences(of: "\"", with: "\\\"")
        let r: Shell.Result
        if on {
            r = Shell.jxa("var se = Application('System Events'); se.loginItems.push(se.LoginItem({path: \"\(path)\", hidden: false})); 'ok'")
            if r.ok { disabled.removeValue(forKey: item.name) }
        } else {
            r = Shell.jxa("var se = Application('System Events'); se.loginItems.byName(\"\(name)\").delete(); 'ok'")
            if r.ok { disabled[item.name] = item.path }
        }
        UserDefaults.standard.set(disabled, forKey: disabledKey)
        return r.ok
    }
}

// MARK: - Background items (launch agents & daemons)

struct BackgroundItem: Identifiable, Hashable, Codable {
    var id: String { plist.path }
    let label: String
    let plist: URL
    let program: String
    let scope: Scope
    var enabled: Bool
    let runAtLoad: Bool
    /// App propriétaire et nom affiché, cherchés une seule fois à la création (recherche LaunchServices : jamais pendant l'affichage).
    let ownerApp: URL?
    let displayName: String

    enum Scope: String, Codable { case user = "Votre compte", allUsers = "Tous les comptes", system = "Système (démon)" }

    init(label: String, plist: URL, program: String, scope: Scope, enabled: Bool, runAtLoad: Bool) {
        self.label = label; self.plist = plist; self.program = program; self.scope = scope; self.enabled = enabled; self.runAtLoad = runAtLoad
        let comps = label.split(separator: ".")
        if let r = program.range(of: ".app/") { ownerApp = URL(fileURLWithPath: String(program[..<r.lowerBound]) + ".app") }
        else if comps.count >= 3 { ownerApp = FS.appURL(forBundleID: comps.prefix(3).joined(separator: ".")) }
        else { ownerApp = nil }
        displayName = ownerApp.map(FS.displayName) ?? label
    }
}

enum BackgroundItems {
    static func disabledLabels(_ domain: String) -> Set<String> {
        let out = Shell.run("/bin/launchctl", ["print-disabled", domain]).out
        var s = Set<String>()
        for l in out.components(separatedBy: "\n") where l.contains("=>") {
            let parts = l.components(separatedBy: "=>")
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let v = parts[1].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("disabled") || v.hasPrefix("true") { s.insert(label) }
        }
        return s
    }

    static func list() -> [BackgroundItem] {
        let uid = getuid()
        let guiOff = disabledLabels("gui/\(uid)")
        let sysOff = disabledLabels("system")
        let dirs: [(URL, BackgroundItem.Scope)] = [(FS.lib("LaunchAgents"), .user),
                                                   (URL(fileURLWithPath: "/Library/LaunchAgents"), .allUsers),
                                                   (URL(fileURLWithPath: "/Library/LaunchDaemons"), .system)]
        var out: [BackgroundItem] = []
        for (dir, scope) in dirs {
            for f in FS.children(dir) where f.pathExtension == "plist" {
                let d = FS.plist(f) ?? [:]
                let label = d["Label"] as? String ?? f.deletingPathExtension().lastPathComponent
                let prog = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first ?? ""
                let off = (scope == .system ? sysOff : guiOff).contains(label) || (d["Disabled"] as? Bool == true)
                out.append(BackgroundItem(label: label, plist: f, program: prog, scope: scope, enabled: !off, runAtLoad: d["RunAtLoad"] as? Bool ?? false))
            }
        }
        return out.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func setEnabled(_ i: BackgroundItem, _ on: Bool) -> Bool {
        let uid = getuid()
        let label = Shell.q(i.label), path = Shell.q(i.plist.path)
        if i.scope == .system {
            let cmd = on ? "launchctl enable system/\(label); launchctl bootstrap system \(path)"
                         : "launchctl disable system/\(label); launchctl bootout system/\(label)"
            return Shell.admin(cmd + " ; true").ok
        }
        let cmd = on ? "launchctl enable gui/\(uid)/\(label); launchctl bootstrap gui/\(uid) \(path)"
                     : "launchctl disable gui/\(uid)/\(label); launchctl bootout gui/\(uid)/\(label)"
        Shell.sh(cmd)
        return disabledLabels("gui/\(uid)").contains(i.label) != on
    }

    static func remove(_ i: BackgroundItem) -> Bool {
        if Ignore.removalBlocker(i.plist) != nil { return false }
        _ = setEnabled(i, false)
        if i.scope == .user { return (try? FS.trash(i.plist)) != nil }
        return Shell.admin(FS.adminTrashCommand(i.plist)).ok
    }
}
