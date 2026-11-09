import Foundation

/// `zerOS --selftest [modules]` : runs every scanner read-only and prints what it found. Nothing is deleted.
/// Launched from the app bundle (`open -n -a zerOS --args --selftest`), the output goes to
/// `~/Library/Application Support/zerOS/selftest.txt`, so the run benefits from zerOS's Full Disk Access.
enum SelfTest {
    static var outputFile: URL { FS.support.appendingPathComponent("selftest.txt") }

    static func run() {
        let args = CommandLine.arguments
        let next = args.drop { $0 != "--selftest" }.dropFirst().first
        let wanted = next.flatMap { $0.hasPrefix("-") ? nil : $0.components(separatedBy: ",") } ?? []
        func want(_ k: String) -> Bool { wanted.isEmpty || wanted.contains(k) }
        if Bundle.main.bundleURL.pathExtension == "app" {
            try? FileManager.default.createDirectory(at: FS.support, withIntermediateDirectories: true)
            freopen(outputFile.path, "w", stdout)
            freopen(outputFile.path, "a", stderr)
            setvbuf(stdout, nil, _IOLBF, 0)
        }
        let start = Date()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            let rep = Reporter.silent
            func show(_ name: String, _ groups: [CleanGroup], _ t0: Date) {
                print("\n=== \(name) (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s) ===")
                for g in groups.map({ $0.protected() }) {
                    let ro = g.items.filter(\.readOnly)
                    print("  [\(g.infoOnly ? "info" : "    ")] \(g.title): \(g.items.count) éléments, \(Fmt.bytes(g.size)), coché par défaut \(Fmt.bytes(g.items.filter(\.preselected).reduce(0) { $0 + $1.size }))"
                          + (ro.isEmpty ? "" : ", lecture seule \(ro.count) (\(Fmt.bytes(ro.reduce(0) { $0 + $1.size })))"))
                    for i in g.items.prefix(3) { print("        · \(i.readOnly ? "🔒 " : "")\(i.title) — \(Fmt.bytes(i.size)) — \(i.subtitle)") }
                }
            }
            print("zerOS autotest — \(Fmt.dateTime(Date())) — \(Bundle.main.bundleURL.path)")
            print("Accès complet au disque : \(Perms.fullDiskAccess ? "oui" : "non")")
            print("Lecture seule : " + Ignore.readOnlyPaths.map { $0.replacingOccurrences(of: FS.home.path, with: "~") }.joined(separator: ", "))
            if want("junk") { let t = Date(); show("Déchets système", await Junk.scanAll(rep), t) }
            if want("caches") {
                let t = Date(); let g = CacheScan.scan(rep)
                show("Caches", g, t)
                let ram = Fmt.mem(Int64(ProcessInfo.processInfo.physicalMemory))
                print("  Mémoire vive (convention binaire) : \(ram) — \(ProcessInfo.processInfo.physicalMemory % (1 << 30) != 0 || ram == "\(ProcessInfo.processInfo.physicalMemory >> 30) Go" ? "✓" : "✗ attendu un nombre rond de Go")")
                for grp in g.map({ $0.protected() }) {
                    print("  — \(grp.title) : détail")
                    for i in grp.items { print("        · \(i.readOnly ? "🔒 " : "")\(i.title) — \(Fmt.bytes(i.size)) — coché: \(i.preselected ? "oui" : "non") — \(i.subtitle)") }
                    if let n = grp.note { for l in n.split(separator: "\n") { print("        note : \(l)") } }
                }
                CacheExceptionTests.run()
            }
            if want("mail") { let t = Date(); show("Pièces jointes Mail", [MailJunk.scan()], t) }
            if want("trash") { print("\n=== Corbeilles (relevé, lecture seule) ==="); for b in TrashBins.bins() { print("  \(b.title) : \(b.readable ? "\(Fmt.count(b.count, "élément")), \(Fmt.bytes(b.size)), dont \(b.recent) mis par zerOS depuis 24 h" : "illisible (accès complet au disque)")") } }
            if want("ai") { let t = Date(); show("Encombrement IA", AIClutter.scan(), t) }
            if want("apps") {
                let t = Date(); let a = AppCatalog.list()
                print("\n=== Apps (\(String(format: "%.1f", Date().timeIntervalSince(t))) s) === \(a.count) apps, \(Fmt.bytes(a.reduce(0) { $0 + $1.size }))")
                for x in a.prefix(5) { print("  · \(x.name) \(x.version) — \(Fmt.bytes(x.size)) — utilisée \(Fmt.ago(x.lastUsed)) — rel: \(AppCatalog.relatedFiles(for: x).count)") }
            }
            if want("leftovers") { let t = Date(); show("Restes d'apps", await AppCatalog.leftovers(rep), t) }
            if want("installers") { let t = Date(); show("Installateurs", await AppCatalog.installers(rep), t) }
            if want("updates") {
                let t = Date(); let u = await Updater.check(rep)
                print("\n=== Mises à jour (\(String(format: "%.1f", Date().timeIntervalSince(t))) s) ===")
                for x in u { print("  · \(x.appName) \(x.current) → \(x.latest)") }
            }
            if want("large") { let t = Date(); show("Gros et anciens fichiers", await Clutter.largeOld(rep), t) }
            if want("dupes") { let t = Date(); let g = await Clutter.duplicates(rep); show("Doublons (\(g.count) séries)", Array(g.prefix(5)), t) }
            if want("similar") { let t = Date(); let g = await Clutter.similarImages(rep, cap: 400); show("Images similaires (\(g.count) séries)", Array(g.prefix(5)), t) }
            if want("downloads") { let t = Date(); show("Téléchargements", await Clutter.downloads(rep), t) }
            if want("cloud") {
                print("\nFournisseurs cloud : " + CloudCleanup.providers().map(\.name).joined(separator: ", "))
                let t = Date(); show("Cloud", await CloudCleanup.scan(rep), t)
            }
            if want("background") {
                let b = BackgroundItems.list()
                print("\n=== Arrière-plan === \(b.count) éléments")
                for x in b.prefix(8) { print("  · \(x.displayName) [\(x.scope.rawValue)] \(x.enabled ? "actif" : "désactivé")") }
            }
            if want("snapshots") { print("\n=== Instantanés locaux === \(Snapshots.list().count)") }
            if want("system") {
                print("\n=== Système ===")
                if let b = SystemMonitor.batteryInfo() { print("  Batterie \(b.percent) % · santé \(b.health) % · \(b.cycles) cycles · \(b.temperature) °C") }
                let d = SystemMonitor.disk(); print("  Disque : \(Fmt.bytes(d.1)) libres / \(Fmt.bytes(d.0)) (strict \(Fmt.bytes(d.2)))")
                print("  SMART : \(SystemMonitor.smartStatus()) · allumé depuis \(Fmt.uptime(SystemMonitor.bootUptime()))")
                for x in SystemMonitor.connectedDevices() { print("  Appareil : \(x.name) — \(x.detail) \(x.battery.map { "\($0) %" } ?? "")") }
                for p in Processes.byApp().sorted(by: { $0.memory > $1.memory }).prefix(5) { print("  Mémoire : \(p.name) \(Fmt.mem(p.memory))") }
                print("  Apple Intelligence : \(SmartInsights.isAvailable ? "disponible" : SmartInsights.unavailableReason)")
            }
            if want("today") { TodayTests.run() }
            if want("services") { ServiceTests.run() }
            if want("protection") { ProtectionTests.run() }
            if want("securite") { await CleanupSafetyTests.run() }
            if want("config") { ConfigTests.run() }
            if want("alerts") { AlertTests.run() }
            if want("health") { HealthTests.run() }
            if want("storage") { StorageTests.run(real: wanted.contains("storage")) }
            if wanted.contains("stress") { StressTests.run() }
            print("\nAUTOTEST TERMINÉ en \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
            fflush(stdout)
            sem.signal()
        }
        // Le fil principal reste libre de travailler : certains contrôles (icône de la barre des menus, assistant) doivent s'y exécuter.
        while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
}

/// Protection levels on a dummy folder tree in a temporary folder (only that dummy data is removed).
enum ProtectionTests {
    static func run() {
        print("\n=== Protection (dossier factice) ===")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("zerOS-autotest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        var fails = 0
        func check(_ name: String, _ ok: Bool) { print("  \(ok ? "✓" : "✗") \(name)"); if !ok { fails += 1 } }
        func mk(_ rel: String, file: Bool = false) -> URL {
            let u = root.appendingPathComponent(rel)
            if file {
                try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: u.path, contents: Data("x".utf8))
            } else { try? fm.createDirectory(at: u, withIntermediateDirectories: true) }
            return u
        }
        let withLogic = mk("Bureau/Vieux trucs")
        _ = mk("Bureau/Vieux trucs/Morceau.logicx/Alternatives/000/ProjectData", file: true)
        let withAbleton = mk("Bureau/Sessions")
        _ = mk("Bureau/Sessions/Live Set Project/Ableton Project Info/info.cfg", file: true)
        let withPSD = mk("Bureau/Graphisme")
        _ = mk("Bureau/Graphisme/a/b/c/d/e/affiche.psd", file: true)
        let plain = mk("Bureau/Normal")
        _ = mk("Bureau/Normal/notes.txt", file: true)
        let big = mk("Bureau/Gros")
        for i in 0..<1200 { _ = mk("Bureau/Gros/f\(i).txt", file: true) }
        let als = mk("Bureau/morceau.als", file: true)

        check("fichier .als en lecture seule", Ignore.readOnly(als))
        check("fichier dans un .logicx en lecture seule", Ignore.readOnly(withLogic.appendingPathComponent("Morceau.logicx/Alternatives")))
        check("dossier normal non protégé", Ignore.removalBlocker(plain) == nil)
        check("dossier contenant un .logicx refusé", Ignore.removalBlocker(withLogic)?.contains("contient un projet protégé") == true)
        check("dossier contenant un projet Ableton refusé", Ignore.removalBlocker(withAbleton)?.contains("contient un projet protégé") == true)
        check("dossier contenant un .psd profond refusé", Ignore.removalBlocker(withPSD)?.contains("contient un projet protégé") == true)
        check("budget dépassé → refusé par prudence", Ignore.checkContents(big, budget: 0) == .unknown)
        check("budget normal → dossier vérifié", Ignore.checkContents(big) == .clean)
        var refused = false
        do { try FS.remove(withLogic) } catch { refused = true; print("    message : \(error.localizedDescription)") }
        check("FS.remove refuse et le projet reste en place", refused && fm.fileExists(atPath: withLogic.appendingPathComponent("Morceau.logicx").path))
        check("FS.remove supprime le dossier factice normal", (try? FS.remove(plain)) != nil && !fm.fileExists(atPath: plain.path))

        // Uninstaller: admin removals and the app itself go through removalBlocker (nothing is run here).
        let support = mk("Library/Application Support/com.exemple.truc")
        _ = mk("Library/Application Support/com.exemple.truc/cache.db", file: true)
        let files = [CleanItem(url: support, title: "support", mode: .adminTrash),
                     CleanItem(url: withLogic, title: "logic", mode: .adminTrash),
                     CleanItem(url: als, title: "als", mode: .adminTrash)]
        let plan = AppCatalog.adminPlan(files)
        check("désinstalleur : fichier système normal accepté (mis à la Corbeille avec le mot de passe)", plan.items.map(\.title) == ["support"])
        check("désinstalleur : projet et lecture seule refusés avant la commande administrateur", plan.refused.count == 2)
        let app = mk("Bureau/Outil.app")
        _ = mk("Bureau/Outil.app/Contents/Resources/demo.als", file: true)
        let info = AppInfo(url: app, name: "Outil", bundleID: nil, version: "", build: "", size: 0, lastUsed: nil, isAppStore: false, isApple: false, feedURL: nil)
        let r = AppCatalog.uninstall(info, files: [], keepApp: false)
        check("désinstalleur : app contenant un projet refusée et laissée en place", !r.errors.isEmpty && fm.fileExists(atPath: app.path))

        // Never-downloaded cloud folder (read-only check on a real one in iCloud Drive, if there is one).
        let icloud = FS.lib("Mobile Documents")
        var dataless: URL?
        if FS.responds(icloud) {
            outer: for a in FS.children(icloud) {
                for b in [a] + FS.children(a) + FS.children(a.appendingPathComponent("Documents")) where CloudCleanup.isDatalessDir(b) { dataless = b; break outer }
            }
        }
        if let d = dataless {
            check("dossier cloud non téléchargé refusé (\(d.lastPathComponent))", Ignore.removalBlocker(d)?.contains("cloud non téléchargé") == true)
            print("    message : \(Ignore.removalBlocker(d) ?? "—")")
        } else {
            print("  – dossier cloud non téléchargé : aucun trouvé dans iCloud Drive, non testé")
        }
        print(fails == 0 ? "  Tout est bon." : "  \(fails) échec(s).")
    }
}

/// « Aujourd'hui » : états et actions sur les données réelles, puis sur des cas fixes pour vérifier les seuils.
enum TodayTests {
    static func run() {
        print("\n=== Aujourd'hui ===")
        var fails = 0
        func check(_ name: String, _ ok: Bool) { print("  \(ok ? "✓" : "✗") \(name)"); if !ok { fails += 1 } }
        let live = TodaySnapshot.live()
        print("  Données réelles : disque \(Fmt.bytes(live.diskFree)) libres / \(Fmt.bytes(live.diskTotal)), pression \(live.pressure), échange \(Fmt.mem(live.swapUsed)), Corbeille \(Fmt.bytes(live.trashSize))")
        for e in live.externals { print("  Externe : \(e.name) — \(Fmt.bytes(e.free)) libres / \(Fmt.bytes(e.total))") }
        for st in TodayEngine.states(live) { print("  [\(st.level.label)] \(st.title) : \(st.value) — \(st.detail)") }
        let acts = TodayEngine.actions(live)
        for a in acts { print("  Action [\(a.level.label)] \(a.title) (\(a.button))") }
        if acts.isEmpty { print("  Aucune action sur les données réelles.") }
        check("au plus \(Thresholds.maxActions) actions", acts.count <= Thresholds.maxActions)

        // Cas fixes.
        let GB: Int64 = 1_000_000_000
        let now = Date()
        func snap(free: Int64 = 400 * GB, pressure: Int = 1, swap: Int64 = 0, backupDays: Int? = 1, plugged: Bool = true, externals: [DeviceInfo] = [], trash: Int64 = 0) -> TodaySnapshot {
            var s = TodaySnapshot(diskFree: free, diskTotal: 1000 * GB,
                          pressure: pressure, swapUsed: swap, memTotal: 24 * 1_073_741_824, externals: externals, trashSize: trash, now: now)
            _ = (backupDays, plugged)
            return s
        }
        func drive(_ free: Int64) -> DeviceInfo { DeviceInfo(name: "TEST", kind: "drive", detail: "", battery: nil, url: nil, free: free, total: 1000 * GB, external: true) }
        check("disque 50 % libre → vert", TodayEngine.disk(snap(free: 500 * GB)).level == .green)
        check("disque 15 % libre → orange", TodayEngine.disk(snap(free: 150 * GB)).level == .orange)
        check("disque 5 % libre → rouge", TodayEngine.disk(snap(free: 50 * GB)).level == .red)
        let maxDaysBad = 30
        check("mémoire normale, échange nul → vert", TodayEngine.memory(snap()).level == .green)
        check("pression élevée → orange", TodayEngine.memory(snap(pressure: 2)).level == .orange)
        check("pression critique → rouge", TodayEngine.memory(snap(pressure: 4)).level == .red)
        check("échange 4 Go sur 24 → orange", TodayEngine.memory(snap(swap: 4 * 1_073_741_824)).level == .orange)
        check("échange 8 Go sur 24 → rouge", TodayEngine.memory(snap(swap: 8 * 1_073_741_824)).level == .red)
        check("aucun disque externe → vert", TodayEngine.externals(snap()).level == .green)
        check("externe à 3 % libre → rouge", TodayEngine.externals(snap(externals: [drive(30 * GB), drive(600 * GB)])).level == .red)
        check("tout vert → aucune action", TodayEngine.actions(snap()).isEmpty)
        let bad = snap(free: 50 * GB, pressure: 4, backupDays: maxDaysBad, plugged: false, externals: [drive(10 * GB)], trash: 5 * GB)
        let badActions = TodayEngine.actions(bad)
        check("tout rouge → 3 actions au plus", badActions.count == Thresholds.maxActions)
        check("actions triées du plus grave au moins grave", badActions.map(\.level) == badActions.map(\.level).sorted(by: >))
        print("  Cas tout rouge : " + badActions.map(\.title).joined(separator: " | "))
        var withCaches = snap(free: 150 * GB); withCaches.reclaimable = 2_100_000_000
        check("caches mesurés → « Supprimer … de caches régénérables »", TodayEngine.actions(withCaches).first?.title.hasPrefix("Supprimer") == true)
        print(fails == 0 ? "  Tout est bon." : "  \(fails) échec(s).")
    }
}

/// Services d'arrière-plan : ce que la désinstallation trouverait pour 3 apps installées, et les services orphelins. Lecture seule.
enum ServiceTests {
    static func run() {
        print("\n=== Services d'arrière-plan ===")
        var fails = 0
        func check(_ name: String, _ ok: Bool) { print("  \(ok ? "✓" : "✗") \(name)"); if !ok { fails += 1 } }
        let items = BackgroundItems.list()
        print("  \(items.count) services installés")

        // Cas fixes.
        let fake = AppInfo(url: URL(fileURLWithPath: "/Applications/Truc.app"), name: "Truc", bundleID: "com.exemple.truc", version: "", build: "", size: 0, lastUsed: nil, isAppStore: false, isApple: false, feedURL: nil)
        func svc(_ label: String, _ program: String, scope: BackgroundItem.Scope = .user) -> BackgroundItem {
            BackgroundItem(label: label, plist: URL(fileURLWithPath: "/tmp/\(label).plist"), program: program, scope: scope, enabled: true, runAtLoad: true)
        }
        var cache: [String: String?] = [:]
        let l = Services.linked(to: fake, items: [svc("com.exemple.truc.helper", "/x"), svc("com.exemple.truc", "/x"), svc("com.exemple.autre", "/x"),
                                                  svc("com.apple.truc", "/x"), svc("zz.dans-app", "/Applications/Truc.app/Contents/MacOS/h")], teamCache: &cache)
        check("lié par identifiant et par programme dans l'app (3 attendus)", Set(l.map(\.item.label)) == ["com.exemple.truc.helper", "com.exemple.truc", "zz.dans-app"])
        let o = Services.orphans(items: [svc("com.exemple.mort", "/Applications/Disparue.app/Contents/MacOS/x"), svc("com.exemple.vivant", "/bin/ls"),
                                         svc("com.apple.mort", "/inexistant"), svc("com.exemple.volume", "/Volumes/DEBRANCHE/x")])
        check("orphelin = programme introuvable (Apple et volumes débranchés ignorés)", o.map(\.item.label) == ["com.exemple.mort"])
        // 2e règle : programme présent hors d'une app, aucune app du même éditeur ni du même Team ID (cas Google Keystone).
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zerOS-services-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        func prog(_ n: String) -> String { let p = tmp.appendingPathComponent(n).path; FileManager.default.createFile(atPath: p, contents: Data()); return p }
        let keystone = prog("GoogleSoftwareUpdateAgent"), sameTeam = prog("aide"), samePrefix = prog("maj"), unsigned = prog("brew")
        let teams = [keystone: "EQHXZ8M8AV", sameTeam: "AAAA111111", samePrefix: "CCCC333333"]
        let p = Services.probableOrphans(items: [svc("com.google.keystone.agent", keystone), svc("com.autre.aide", sameTeam),
                                                 svc("com.exemple.maj", samePrefix), svc("homebrew.mxcl.truc", unsigned)],
                                         owners: [Services.Owner(prefix: "com.exemple", team: "AAAA111111")], teamOf: { teams[$0] })
        check("orphelin probable : éditeur et Team ID absents des apps installées (Keystone), app du même éditeur ou Team ID et programme non signé ignorés",
              p.map(\.item.label) == ["com.google.keystone.agent"])
        if let r = p.first?.why { print("    raison affichée : \(r)") }
        let daemon = URL(fileURLWithPath: "/Library/LaunchDaemons/com.exemple.daemon.plist")
        check("démon système : arrêt réservé à la commande administrateur (rien n'est lancé ici)", Services.bootoutCommand(plist: daemon) != nil && !Services.stop(plist: daemon))
        check("protégé : aucun arrêt ni suppression d'un service dans une zone protégée",
              Ignore.removalBlocker(FS.home.appendingPathComponent(".ssh/x.plist")) != nil)

        // Données réelles : 3 apps (celles qui ont des services d'abord, Chrome en tête).
        let apps = AppCatalog.list().filter { !$0.isApple }
        var picked: [(AppInfo, [LinkedService])] = []
        var rest: [AppInfo] = []
        cache = [:]
        for a in apps.sorted(by: { ($0.name.contains("Chrome") ? 0 : 1, $0.name) < ($1.name.contains("Chrome") ? 0 : 1, $1.name) }) {
            let ls = Services.linked(to: a, items: items, teamCache: &cache)
            if !ls.isEmpty { picked.append((a, ls)) } else { rest.append(a) }
            if picked.count == 3 { break }
        }
        for a in rest.prefix(3 - picked.count) { picked.append((a, [])) }
        for (a, ls) in picked {
            print("  App « \(a.name) » (\(a.bundleID ?? "?")) — \(ls.count) service(s) rattaché(s)")
            for x in ls {
                print("      · \(x.item.label) [\(x.item.scope.rawValue)] — \(x.reasons.joined(separator: ", "))\(x.sharedWith.map { " — PARTAGÉ avec \($0), décoché" } ?? "") — \(x.item.plist.path.replacingOccurrences(of: FS.home.path, with: "~"))")
                print("        refus de protection : \(Ignore.removalBlocker(x.item.plist) ?? "aucun") ; programme : \(x.item.program.replacingOccurrences(of: FS.home.path, with: "~"))")
            }
            let rel = AppCatalog.relatedFiles(for: a)
            print("      fichiers liés au total : \(rel.count) (dont services : \(rel.filter { Services.isServicePlist($0.url ?? URL(fileURLWithPath: "/")) }.count))")
        }
        let orph = Services.orphans(items: items) + Services.probableOrphans(items: items)
        print("  Services orphelins (programme introuvable + orphelins probables) : \(orph.count)")
        for x in orph.prefix(10) { print("      · \(x.item.label) [\(x.item.scope.rawValue)] — \(x.why)") }
        print(fails == 0 ? "  Tout est bon." : "  \(fails) échec(s).")
    }
}

/// Exception SPEC.md : caches Adobe lus dans les préférences, vidables même sur un volume en lecture seule. Rien n'est vidé ici.
enum CacheExceptionTests {
    static func run() {
        print("\n=== Caches Adobe (préférences) et caches de développement ignorés ===")
        var fails = 0
        func check(_ name: String, _ ok: Bool) { print("  \(ok ? "✓" : "✗") \(name)"); if !ok { fails += 1 } }
        let p = CacheScan.premierePrefs()
        print("  Premiere (com.Adobe.Common) : Media Cache \(p.mediaCache?.path ?? "emplacement par défaut"), base \(p.mediaCacheDatabase?.path ?? "—")")
        if let ae = CacheScan.afterEffectsPrefs() { print("  After Effects \(ae.version) : cache disque \(ae.folder.path), \(ae.maxGB) Go max") }
        let folders = CacheScan.prefsCacheFolders()
        for f in folders { print("  · \(f.title) — \(f.url.path) — lecture seule normale : \(Ignore.readOnly(f.url) ? "oui" : "non")") }
        let g = CacheScan.prefsCaches().protected()
        check("éléments lus dans les préférences : jamais cochés", g.items.allSatisfy { !$0.preselected })
        check("éléments lus dans les préférences : pas marqués lecture seule (exception)", g.items.allSatisfy { !$0.readOnly })
        check("app Adobe ouverte → non vidable", !CacheScan.adobeRunning || g.items.allSatisfy { $0.mode == .none })
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zerOS-cache-\(UUID().uuidString)/Media Cache Files")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        check("dossier hors des préférences refusé (même nommé « Media Cache Files »)", CacheScan.prefsCacheBlocker(tmp) != nil)
        check("racine d'un volume jamais vidable", !CacheScan.isCacheFolderName("CACHES") && !CacheScan.isCacheFolderName("DONNEES"))
        if let ro = folders.first(where: { Ignore.readOnly($0.url) }) {
            check("le reste de zerOS refuse toujours ce dossier (FS.emptyDirectory)", Ignore.removalBlocker(ro.url) != nil)
            print("    vidage possible maintenant : \(CacheScan.prefsCacheBlocker(ro.url) ?? "oui (non lancé)")")
        }
        print("  Caches de développement ignorés : " + Prefs.ignoredDevCaches.map { $0.replacingOccurrences(of: FS.home.path, with: "~") }.joined(separator: ", "))
        let listed = Junk.userCaches().items.compactMap(\.url?.path)
        check("caches de développement ignorés absents du nettoyage", !listed.contains { Prefs.ignoredDevCaches.contains($0) })
        print(fails == 0 ? "  Tout est bon." : "  \(fails) échec(s).")
    }
}

/// Images disque temporaires (hdiutil) pour les autotests : jamais un vrai disque. Créées sous un dossier temporaire, détachées à la fin.
enum DiskImage {

    struct Image { let dev: String; let mount: URL; let file: URL }

    static func attach(_ file: URL, at mount: URL) -> Image? {
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let r = Shell.run("/usr/bin/hdiutil", ["attach", "-plist", "-nobrowse", "-mountpoint", mount.path, file.path])
        guard let d = r.out.data(using: .utf8), let pl = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
              let ents = pl["system-entities"] as? [[String: Any]] else { return nil }
        let devs = ents.compactMap { $0["dev-entry"] as? String }.sorted { $0.count < $1.count }
        return devs.first.map { Image(dev: $0, mount: mount, file: file) }
    }

    static func make(_ root: URL, _ name: String, fs: String, mb: Int) -> Image? {
        let file = root.appendingPathComponent("\(name).dmg")
        guard Shell.run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "\(mb)m", "-fs", fs, "-volname", name, file.path]).ok else { return nil }
        return attach(file, at: root.appendingPathComponent("mnt-\(name)"))
    }

    /// Image montée comme un disque externe (dans /Volumes, sans apparaître dans le Finder) : le fichier reste dans `root`.
    static func makeExternal(_ root: URL, _ name: String, mb: Int = 20) -> Image? {
        let file = root.appendingPathComponent("\(name).dmg")
        guard Shell.run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "\(mb)m", "-fs", "APFS", "-volname", name, file.path]).ok else { return nil }
        let r = Shell.run("/usr/bin/hdiutil", ["attach", "-plist", "-nobrowse", file.path])
        guard let d = r.out.data(using: .utf8), let pl = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
              let ents = pl["system-entities"] as? [[String: Any]],
              let mount = ents.compactMap({ $0["mount-point"] as? String }).first else { return nil }
        let dev = ents.compactMap { $0["dev-entry"] as? String }.sorted { $0.count < $1.count }.first ?? ""
        return Image(dev: dev, mount: URL(fileURLWithPath: mount), file: file)
    }

    static func detach(_ i: Image) { _ = Shell.run("/usr/bin/hdiutil", ["detach", "-force", "-quiet", i.dev]) }
}
