import Foundation
import SwiftUI
import AppKit

struct HealthFactor: Identifiable {
    let id: String
    let title: String
    let detail: String
    let severity: Int    // 0 ok, 1 to watch, 2 critical
    let symbol: String
    var target: Module? = nil
}

@MainActor
enum Health {
    static var pendingUpdates: Int? {
        get { UserDefaults.standard.object(forKey: "pendingUpdates") as? Int }
        set { UserDefaults.standard.set(newValue, forKey: "pendingUpdates") }
    }
    static var unusedApps: Int? {
        get { UserDefaults.standard.object(forKey: "unusedApps") as? Int }
        set { UserDefaults.standard.set(newValue, forKey: "unusedApps") }
    }

    /// State of the Mac only (disk, battery, memory, updates…), never how zerOS itself is used or configured. Feeds the tips popover.
    static func factors() -> [HealthFactor] {
        let m = SystemMonitor.shared
        var f: [HealthFactor] = []
        if m.diskTotal > 0 {
            let ratio = Double(m.diskFree) / Double(m.diskTotal)
            if ratio < 0.1 { f.append(HealthFactor(id: "disk", title: "Disque presque plein", detail: "Seulement \(Fmt.bytes(m.diskFree)) libres", severity: 2, symbol: "internaldrive", target: .cleanup)) }
            else if ratio < 0.2 { f.append(HealthFactor(id: "disk", title: "Peu d'espace libre", detail: "\(Fmt.bytes(m.diskFree)) libres", severity: 1, symbol: "internaldrive", target: .cleanup)) }
            else { f.append(HealthFactor(id: "disk", title: "Espace disque", detail: "\(Fmt.bytes(m.diskFree)) libres", severity: 0, symbol: "internaldrive")) }
        }
        if m.smart != "—" && m.smart != "Verified" && m.smart != "Vérifié" && m.smart != "Non disponible" && !m.smart.contains("Not Supported") {
            f.append(HealthFactor(id: "smart", title: "État du disque critique", detail: "Statut SMART : \(m.smart). Sauvegardez vos données.", severity: 2, symbol: "exclamationmark.octagon"))
        }
        if let b = m.battery {
            if b.health < 70 { f.append(HealthFactor(id: "bat", title: "Batterie usée", detail: "Capacité à \(Fmt.percent(Double(b.health))) de l'origine", severity: 2, symbol: "battery.25")) }
            else if b.health < 80 { f.append(HealthFactor(id: "bat", title: "Batterie fatiguée", detail: "Capacité à \(Fmt.percent(Double(b.health))) de l'origine", severity: 1, symbol: "battery.50")) }
            else { f.append(HealthFactor(id: "bat", title: "Batterie", detail: "\(Fmt.percent(Double(b.health))) de capacité, \(b.cycles) cycles", severity: 0, symbol: "battery.100")) }
        }
        if m.trashSize > 2_000_000_000 {
            f.append(HealthFactor(id: "trash", title: "Corbeille trop pleine", detail: "\(Fmt.bytes(m.trashSize)) à récupérer", severity: 1, symbol: "trash", target: .cleanup))
        }
        if m.uptime > 7 * 86400 {
            f.append(HealthFactor(id: "uptime", title: "Mac allumé depuis longtemps", detail: "\(Fmt.uptime(m.uptime)) sans redémarrage", severity: 1, symbol: "power"))
        }
        if m.pressure >= 4 {
            f.append(HealthFactor(id: "mem", title: "Mémoire saturée", detail: "Fermez des apps gourmandes", severity: 2, symbol: "memorychip", target: .performance))
        }
        if let u = pendingUpdates, u > 0 {
            f.append(HealthFactor(id: "updates", title: "Mises à jour en attente", detail: Fmt.count(u, "app à mettre à jour", "apps à mettre à jour"), severity: 1, symbol: "arrow.down.app", target: .applications))
        }
        if let u = unusedApps, u > 5 {
            f.append(HealthFactor(id: "unused", title: "Apps inutilisées", detail: "\(u) apps pas ouvertes depuis 6 mois", severity: 1, symbol: "app.dashed", target: .applications))
        }
        return f.sorted { $0.severity > $1.severity }
    }

    /// Assistant tips, most useful first.
    static func tips() -> [(String, String, Module?)] {
        var t: [(String, String, Module?)] = []
        for f in factors() where f.severity > 0 { t.append((f.title, f.detail, f.target)) }
        let store = ActivityStore.shared
        if store.lastRun["Mon désordre"] == nil { t.append(("Faites le tri dans vos fichiers", "« Mon désordre » repère les doublons et les gros fichiers oubliés.", .clutter)) }
        if store.lastRun["Space Lens"] == nil { t.append(("Voyez ce qui remplit votre disque", "Stockage ▸ Arborescence dessine une carte de votre disque.", .spaceLens)) }
        if store.lastRun["Nettoyage du cloud"] == nil { t.append(("Libérez de la place sans rien perdre", "Gardez vos fichiers iCloud, Google Drive et Dropbox uniquement en ligne.", .cloud)) }
        t.append(("Astuce", "Glissez une app dans la Corbeille : zerOS proposera de supprimer aussi ses restes.", nil))
        return t
    }
}

// MARK: - Trash watcher (app dragged to the Trash → offer leftovers cleanup)

@MainActor
final class TrashWatcher {
    static let shared = TrashWatcher()
    private var source: DispatchSourceFileSystemObject?
    private var known = Set<String>()

    func start() {
        let path = TrashBins.userTrash.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        known = Set(FS.children(TrashBins.userTrash, hidden: true).map(\.lastPathComponent))
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in Task { @MainActor in self?.changed() } }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    private var pending: DispatchWorkItem?

    /// Trash written to: new apps are checked right away, the size is measured once things settle (2 s).
    private func changed() {
        pending?.cancel()
        let w = DispatchWorkItem { Task { @MainActor in SystemMonitor.shared.refreshTrash() } }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
        let now = FS.children(TrashBins.userTrash, hidden: true)
        let names = Set(now.map(\.lastPathComponent))
        let added = now.filter { !known.contains($0.lastPathComponent) && $0.pathExtension == "app" }
        known = names
        for app in added {
            guard UserDefaults.standard.object(forKey: "watchTrash") as? Bool ?? true,
                  let id = FS.bundleInfo(app)?["CFBundleIdentifier"] as? String else { continue }
            let name = FS.displayName(app)
            Task.detached {
                let info = AppInfo(url: app, name: name, bundleID: id, version: "", build: "", size: 0, lastUsed: nil, isAppStore: false, isApple: false, feedURL: nil)
                let files = AppCatalog.relatedFiles(for: info)
                let size = files.reduce(0) { $0 + $1.size }
                guard !files.isEmpty else { return }
                await MainActor.run {
                    UserDefaults.standard.set(id, forKey: "pendingLeftoverBundle")
                    Notifier.deliver([Alerts.appInTrash(name: name, files: files.count, bytes: size)])
                }
            }
        }
    }
}
