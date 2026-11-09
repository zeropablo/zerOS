import Foundation
import AppKit

// MARK: - Caches (browsers, editing software)

/// Browser caches are regenerable and deleted directly (unchecked while the browser is open).
/// Editing-software caches (Premiere, After Effects…) are media derived from the user's footage:
/// analysis only, with the real folder and disk read from the software's own preferences.
enum CacheScan {
    /// Top-level folders of `~/Library/Caches` handled here (so `Junk.userCaches` does not count them twice).
    static var handledNames: Set<String> {
        var s: Set<String> = ["Firefox", "Mozilla", "com.apple.Safari", "company.thebrowser.Browser", "BraveSoftware", "Microsoft Edge"]
        if FS.exists(FS.lib("Caches/Google/Chrome")) { s.insert("Google") }
        return s
    }

    static func scan(_ rep: Reporter) -> [CleanGroup] {
        rep("Caches des navigateurs…")
        let browsers = browserCaches()
        rep("Caches de montage et d'animation…")
        let creative = creativeCaches()
        let prefs = prefsCaches()
        return [browsers, prefs, creative].filter { !$0.items.isEmpty }
    }

    // MARK: Browsers

    static func browserCaches() -> CleanGroup {
        let running = Junk.runningIDs
        var items: [CleanItem] = []
        func add(_ url: URL, _ name: String, bundleID: String, _ detail: String) {
            guard FS.isDir(url), !Ignore.blocked(url) else { return }
            let size = FS.allocatedSize(url)
            guard size > 100_000 else { return }
            let open = running.contains(bundleID)
            items.append(CleanItem(url: url, title: name,
                                   subtitle: open ? "Navigateur ouvert — décoché" : detail,
                                   size: size, mode: .emptyDir, preselected: !open,
                                   iconPath: FS.appURL(forBundleID: bundleID)?.path, symbol: "globe"))
        }
        let caches = FS.lib("Caches")
        // Firefox: one disk cache per profile.
        let ff = caches.appendingPathComponent("Firefox/Profiles")
        for p in FS.children(ff, hidden: true) where !p.lastPathComponent.hasPrefix(".") {
            let profile = p.lastPathComponent.split(separator: ".", maxSplits: 1).last.map(String.init) ?? p.lastPathComponent
            add(p, "Firefox — profil \(profile)", bundleID: "org.mozilla.firefox", "Cache disque, pages et images déjà vues")
        }
        add(caches.appendingPathComponent("Mozilla"), "Firefox — mises à jour", bundleID: "org.mozilla.firefox", "Fichiers de mise à jour téléchargés")
        add(caches.appendingPathComponent("com.apple.Safari"), "Safari", bundleID: "com.apple.Safari", "Cache des pages et des images")
        let chromium: [(String, String, String)] = [
            ("Google/Chrome", "Google Chrome", "com.google.Chrome"),
            ("BraveSoftware/Brave-Browser", "Brave", "com.brave.Browser"),
            ("Microsoft Edge", "Microsoft Edge", "com.microsoft.edgemac"),
            ("company.thebrowser.Browser", "Arc", "company.thebrowser.Browser"),
        ]
        for (path, name, id) in chromium { add(caches.appendingPathComponent(path), name, bundleID: id, "Cache des pages et des images") }
        return CleanGroup(id: "browserCaches", title: "Caches des navigateurs", subtitle: "Pages et images gardées pour aller plus vite",
                          symbol: "globe", items: Junk.sorted(items),
                          note: "Les navigateurs gardent une copie des pages visitées. Elle se reconstruit toute seule ; le premier chargement des sites sera un peu plus lent. Historique, cookies et mots de passe ne sont pas touchés. Un navigateur ouvert est décoché : fermez-le d'abord.", regenerable: true)
    }

    // MARK: Editing software (analysis only)

    struct Location { var title: String; var url: URL; var detail: String }

    static func volumeName(of url: URL) -> String {
        var u = url
        while !FS.exists(u), u.path != "/" { u.deleteLastPathComponent() }
        return (try? u.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? "?"
    }

    static func shortPath(_ u: URL) -> String { u.path.replacingOccurrences(of: FS.home.path, with: "~") }

    static func creativeCaches() -> CleanGroup {
        var items: [CleanItem] = []
        var notes: [String] = []
        func add(_ title: String, _ url: URL, _ what: String, icon: String? = nil) {
            guard FS.isDir(url), FS.responds(url) else { return }
            let size = FS.allocatedSize(url)
            guard size > 100_000 else { return }
            items.append(CleanItem(url: url, title: title, subtitle: "\(what) · sur \(volumeName(of: url)) · \(shortPath(url))",
                                   size: size, mode: .none, preselected: false, iconPath: icon, symbol: "film.stack"))
        }

        // Premiere Pro / Media Encoder / After Effects share Adobe's « Common » folder.
        let premiere = premierePrefs()
        let defaultCommon = FS.lib("Application Support/Adobe/Common")
        let premiereApp = FS.appURL(forBundleID: "com.adobe.PremierePro.26")?.path
        if premiere.mediaCache == nil {
            add("Premiere Pro — Media Cache", defaultCommon.appendingPathComponent("Media Cache Files"), "Fichiers conformés (audio, vidéo)", icon: premiereApp)
            add("Premiere Pro — Media Cache (base)", defaultCommon.appendingPathComponent("Media Cache"), "Base de données du cache", icon: premiereApp)
            add("Premiere Pro — fichiers de pics audio", defaultCommon.appendingPathComponent("Peak Files"), "Formes d'onde", icon: premiereApp)
        } else {
            // Ancien emplacement par défaut, plus utilisé depuis le changement dans les préférences.
            add("Premiere Pro — ancien Media Cache", defaultCommon.appendingPathComponent("Media Cache Files"), "Ancien emplacement, plus utilisé", icon: premiereApp)
            add("Premiere Pro — ancienne base du cache", defaultCommon.appendingPathComponent("Media Cache"), "Ancien emplacement, plus utilisé", icon: premiereApp)
            add("Premiere Pro — anciens fichiers de pics audio", defaultCommon.appendingPathComponent("Peak Files"), "Ancien emplacement, plus utilisé", icon: premiereApp)
        }
        add("Adobe — analyse des médias", defaultCommon.appendingPathComponent("Analyzer Cache Files"), "Analyse de scènes et de la parole", icon: premiereApp)
        add("Adobe — métadonnées", defaultCommon.appendingPathComponent("Metadata Cache"), "Métadonnées des fichiers importés", icon: premiereApp)
        let common = premiere.mediaCache ?? defaultCommon
        notes.append("Premiere Pro : Media Cache sur \(volumeName(of: common)) (\(shortPath(common)))"
                     + (premiere.mediaCache == nil ? ", emplacement par défaut" : ", emplacement choisi dans les préférences")
                     + (premiere.purgeDays.map { ", purge automatique après \($0) jours" } ?? "") + ".")
        if let v = premiere.previewFolder {
            notes.append("Fichiers de prévisualisation : \(shortPath(v)) (sur \(volumeName(of: v))), dans le dossier du projet.")
        }

        if let ae = afterEffectsPrefs() {
            let found = prefsCacheFolders().contains { $0.app == "After Effects" }
            notes.append("After Effects \(ae.version) : cache disque sur \(volumeName(of: ae.folder)) (\(shortPath(ae.folder))), taille maximale \(ae.maxGB) Go\(found ? "" : " (vide pour l'instant)")"
                         + (ae.minFreeGB.map { ", arrêt si moins de \($0) Go libres" } ?? "") + ".")
            let c3d = FS.lib("Caches/Adobe/After Effects/\(ae.version)")
            for d in FS.children(c3d) where d.lastPathComponent.hasPrefix("3D Cache") {
                add("After Effects — cache 3D", d, "Modèles 3D préparés", icon: FS.appURL(forBundleID: "com.adobe.AfterEffects")?.path)
            }
        }
        return CleanGroup(id: "creativeCaches", title: "Caches de montage et d'animation", subtitle: "Premiere Pro, After Effects — analyse seule",
                          symbol: "film.stack", items: Junk.sorted(items), note: notes.joined(separator: "\n"), infoOnly: true)
    }

    // MARK: Cache folders read from the preferences (SPEC.md exception)

    /// Apps whose cache folders are listed here; none may be open while one of them is emptied.
    static let adobeIDPrefixes = ["com.adobe.AfterEffects", "com.adobe.PremierePro", "com.adobe.ame"]
    /// Only these folder names can be emptied, whatever the preferences say (never a volume root or a user folder).
    static func isCacheFolderName(_ n: String) -> Bool {
        ["Media Cache Files", "Media Cache", "Peak Files", "Analyzer Cache Files"].contains(n) || n.localizedCaseInsensitiveContains("disk cache")
    }

    struct PrefsCache: Sendable { var title: String; var url: URL; var app: String }

    /// Cache folders whose location is read from the After Effects / Premiere preferences (not the default location).
    static func prefsCacheFolders() -> [PrefsCache] {
        var out: [PrefsCache] = []
        if let ae = afterEffectsPrefs() {
            // AE creates « <dossier choisi>/Adobe/After Effects/<version>/Disk Cache - <nom du Mac>.noindex ».
            let aeRoot = ae.folder.appendingPathComponent("Adobe/After Effects")
            if FS.responds(ae.folder) {
                for base in [ae.folder, aeRoot] + FS.children(aeRoot) {
                    for d in FS.children(base) where d.lastPathComponent.localizedCaseInsensitiveContains("disk cache") && FS.isDir(d) {
                        out.append(PrefsCache(title: "After Effects — cache disque", url: d, app: "After Effects"))
                    }
                }
            }
        }
        let p = premierePrefs()
        if let folder = p.mediaCache, FS.responds(folder) {
            for (n, t) in [("Media Cache Files", "Premiere Pro — Media Cache"), ("Peak Files", "Premiere Pro — fichiers de pics audio"),
                           ("Analyzer Cache Files", "Adobe — analyse des médias")] {
                let u = folder.appendingPathComponent(n)
                if FS.isDir(u) { out.append(PrefsCache(title: t, url: u, app: "Premiere Pro")) }
            }
            let db = (p.mediaCacheDatabase ?? folder).appendingPathComponent("Media Cache")
            if FS.isDir(db) { out.append(PrefsCache(title: "Premiere Pro — Media Cache (base)", url: db, app: "Premiere Pro")) }
        }
        return out.filter { isCacheFolderName($0.url.lastPathComponent) && $0.url.standardizedFileURL.pathComponents.count >= 4 }
    }

    static var adobeRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { a in adobeIDPrefixes.contains { a.bundleIdentifier?.hasPrefix($0) == true } }
    }

    /// Emptyable even on a read-only volume (SPEC.md): never preselected, Adobe apps closed, confirmation asked (`ResultsView`).
    static func prefsCaches() -> CleanGroup {
        let open = adobeRunning
        let items = prefsCacheFolders().compactMap { c -> CleanItem? in
            let size = FS.allocatedSize(c.url)
            guard size > 100_000 else { return nil }
            return CleanItem(url: c.url, title: c.title,
                             subtitle: (open ? "App Adobe ouverte — fermez-la pour vider · " : "Emplacement lu dans les préférences · ")
                                + "sur \(volumeName(of: c.url)) · \(shortPath(c.url))",
                             size: size, mode: open ? .none : .custom("prefsCache"), preselected: false, symbol: "film.stack")
        }
        return CleanGroup(id: "prefsCaches", title: "Caches Adobe (préférences)", subtitle: "After Effects, Premiere Pro — jamais cochés",
                          symbol: "film.stack", items: Junk.sorted(items),
                          note: "Dossiers de cache choisis dans les préférences d'After Effects et de Premiere Pro. Ils peuvent être vidés même sur un disque en lecture seule, uniquement quand les apps Adobe sont fermées et après confirmation. Les images de prévisualisation seront recalculées.", regenerable: true)
    }

    /// Why a prefs cache folder must not be emptied now (nil = allowed). Re-read at removal time, never trusted from the scan.
    static func prefsCacheBlocker(_ u: URL) -> String? {
        if Ignore.blocked(u) { return "élément bloqué" }
        guard prefsCacheFolders().contains(where: { $0.url.standardizedFileURL == u.standardizedFileURL }) else {
            return "ce dossier n'est plus celui des préférences Adobe"
        }
        if adobeRunning { return "une app Adobe est ouverte" }
        switch Ignore.checkContents(u) {
        case .clean: return nil
        case .protected(let w): return "contient un élément protégé (\(w))"
        case .cloudOnly(let w): return "contient un dossier cloud non téléchargé (\(w))"
        case .unknown: return "contenu trop long à vérifier, gardé par prudence"
        }
    }

    /// Empties the folder (kept itself). Explicit path that bypasses the read-only level, only after `prefsCacheBlocker`.
    static func emptyPrefsCache(_ u: URL) -> (freed: Int64, errors: Int, refused: String?) {
        if let why = prefsCacheBlocker(u) { return (0, 0, why) }
        var freed: Int64 = 0, errors = 0
        for c in FS.children(u, hidden: true) {
            let s = FS.allocatedSize(c)
            do { try FileManager.default.removeItem(at: c); freed += s } catch { errors += 1 }
        }
        return (freed, errors, nil)
    }

    // MARK: Preferences of the editing software

    struct PremierePrefs { var mediaCache: URL?; var mediaCacheDatabase: URL?; var purgeDays: Int?; var previewFolder: URL? }

    /// Media Cache location: newest `~/Library/Preferences/com.Adobe.Common <version>.plist` (« Media Cache » → FolderPath,
    /// DatabasePath), only present when it was moved away from the default. Purge and preview folder: newest Premiere Pro profile.
    static func premierePrefs() -> PremierePrefs {
        var r = PremierePrefs()
        let common = FS.children(FS.lib("Preferences")).filter { $0.lastPathComponent.hasPrefix("com.Adobe.Common ") && $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        for f in common {
            guard let mc = FS.plist(f)?["Media Cache"] as? [String: Any] else { continue }
            if let s = mc["FolderPath"] as? String, s.hasPrefix("/") { r.mediaCache = URL(fileURLWithPath: s) }
            if let s = mc["DatabasePath"] as? String, s.hasPrefix("/") { r.mediaCacheDatabase = URL(fileURLWithPath: s) }
            break
        }
        let root = FS.h("Documents/Adobe/Premiere Pro")
        let versions = FS.children(root).sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        for v in versions {
            for p in FS.children(v) where p.lastPathComponent.hasPrefix("Profile-") {
                let f = p.appendingPathComponent("Adobe Premiere Pro Prefs")
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                if let s = value("Prefs.MediaCache.PurgeDays", in: text) { r.purgeDays = Int(s) }
                for key in ["Prefs.MediaCache.Location", "Prefs.MediaCache.Path", "BE.Prefs.MediaCache.Location", "BE.Prefs.MediaCache.Path"] where r.mediaCache == nil {
                    if let s = value(key, in: text), s.hasPrefix("/") { r.mediaCache = URL(fileURLWithPath: s) }
                }
                if let s = value("BE.Prefs.ScratchDisks.FirstVideoPreviewFolder", in: text), s.hasPrefix("/") { r.previewFolder = URL(fileURLWithPath: s) }
                return r
            }
        }
        return r
    }

    static func value(_ key: String, in xml: String) -> String? {
        guard let a = xml.range(of: "<\(key)") else { return nil }
        guard let gt = xml[a.upperBound...].firstIndex(of: ">") else { return nil }
        let rest = xml[xml.index(after: gt)...]
        guard let end = rest.firstIndex(of: "<") else { return nil }
        let s = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    struct AEPrefs { var version: String; var folder: URL; var maxGB: Int; var minFreeGB: Int? }

    /// Reads « Disk Cache Controls » from the newest After Effects preferences file.
    static func afterEffectsPrefs() -> AEPrefs? {
        let root = FS.lib("Preferences/Adobe/After Effects")
        let versions = FS.children(root).sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        for v in versions {
            let ver = v.lastPathComponent
            let files = FS.children(v).filter { $0.lastPathComponent.hasSuffix(".txt") && !$0.lastPathComponent.contains("indep") && $0.lastPathComponent.contains("fs.txt") }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for f in files {
                guard let t = try? String(contentsOf: f, encoding: .utf8), let sec = t.range(of: "[\"Disk Cache Controls\"]") else { continue }
                let body = String(t[sec.upperBound...].prefix(600))
                func get(_ k: String) -> String? {
                    guard let r = body.range(of: "\"\(k)\" = \"") else { return nil }
                    let tail = body[r.upperBound...]
                    return tail.firstIndex(of: "\"").map { String(tail[..<$0]) }
                }
                guard let folder = get("Folder 7"), !folder.isEmpty else { continue }
                let extra = t.range(of: "\"Minimum Volume Free Space (Gigabytes)\" = \"").flatMap { r -> Int? in
                    let tail = t[r.upperBound...]; return tail.firstIndex(of: "\"").flatMap { Int(tail[..<$0]) }
                }
                return AEPrefs(version: ver, folder: URL(fileURLWithPath: folder), maxGB: Int(get("Max Size 3") ?? "") ?? 0, minFreeGB: extra)
            }
        }
        return nil
    }
}
