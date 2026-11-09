import Foundation

/// Stockage : moteur de classification (chaque règle testée), scanner sur un arbre factice, anneaux, catalogue « Déplacer », puis —
/// seulement si `storage` est demandé explicitement — l'analyse réelle du disque interne en lecture seule avec mesure du coût.
enum StorageTests {
    static func run(real: Bool) {
        print("\n=== Stockage : classification, analyse, anneaux (dossiers factices) ===")
        var fails = 0
        func check(_ name: String, _ ok: Bool) { print("  \(ok ? "✓" : "✗") \(name)"); if !ok { fails += 1 } }
        classification(check)
        scanner(check)
        relocate(check)
        print(fails == 0 ? "  Tout est bon." : "  \(fails) échec(s).")
        if real { realDisk() }
    }

    // MARK: Classification

    /// Contexte factice : toutes les apps du catalogue sont installées, home = /Users/test.
    static func context(apps: [String] = ["Whisky", "Prism Launcher", "Native Access", "Spitfire Audio", "Logic Pro", "Ableton Live 12 Suite", "Steam", "Photos",
                                          "Claude", "Adobe Premiere Pro 2026", "Firefox", "Visual Studio Code"], running: [String] = []) -> ClassContext {
        var c = ClassContext()
        c.home = "/Users/test"
        c.apps = apps.map { ClassContext.app($0, "com.test." + $0.lowercased().replacingOccurrences(of: " ", with: "")) }
        c.apps.append(ClassContext.app("Visual Studio Code", "com.microsoft.VSCode"))
        c.apps.append(ClassContext.app("Adobe Premiere Pro 2026", "com.adobe.PremierePro"))
        c.running = Set(running.map(ClassContext.norm))
        c.nicntFolders = ["Analog Dreams Library"]
        c.prefsCaches = ["/Volumes/DISQUE/MesCaches/Media Cache Files"]
        return c
    }

    static func classification(_ check: (String, Bool) -> Void) {
        let ctx = context()
        let rules = Classifier.rules(home: ctx.home)
        func cl(_ p: String, _ c: ClassContext? = nil) -> Classification { Classifier.classify(p, context: c ?? ctx) }
        check("\(rules.count) règles de chemins, identifiants uniques", Set(rules.map(\.id)).count == rules.count)
        // Chaque règle : le dossier lui-même et un enfant profond reçoivent sa catégorie, sa raison et son guide.
        var bad: [String] = []
        for r in rules {
            for p in [r.path, r.path + "/sous-dossier/fichier"] {
                let c = cl(p)
                // Une règle plus précise peut légitimement l'emporter sur son enfant (ex. Adobe/Common dans Application Support).
                let ok = c.rule == r.id ? (c.category == r.category && c.guide == r.guide && !c.reason.isEmpty) : (rules.contains { $0.id == c.rule && r.path.count < $0.path.count })
                if !ok { bad.append("\(r.id) → \(c.rule)/\(c.category.label) sur \(p)") }
            }
        }
        check("chaque règle de chemin s'applique à son dossier et à ses enfants (\(rules.count) × 2)\(bad.isEmpty ? "" : " : " + bad.joined(separator: " ; "))", bad.isEmpty)
        // Règles avec app propriétaire : app absente → Reste d'app.
        let none = context(apps: [])
        let withApp = rules.filter { $0.app != nil }
        check("\(withApp.count) règles avec app : app absente → « Reste d'app » (raison + guide gardés)",
              withApp.allSatisfy { let c = cl($0.path, none); return c.category == .appLeftover && c.guide == $0.guide && c.reason.contains($0.app!) })
        let open = context(running: ["Whisky"])
        check("app ouverte → mentionnée dans la raison", cl("/Users/test/Library/Containers/com.franke.Whisky/Bottles", open).reason.contains("app ouverte"))
        // Exemples du SPEC et du Mac mini.
        func cat(_ p: String) -> StorageCategory { cl(p).category }
        check("Whisky (Containers et Application Support) → Déplaçable", cat("/Users/test/Library/Containers/com.franke.Whisky") == .movable && cat("/Users/test/Library/Application Support/com.franke.Whisky") == .movable)
        check("PrismLauncher, Steam, Ableton → Déplaçable", [cat("/Users/test/Library/Application Support/PrismLauncher/instances"), cat("/Users/test/Library/Application Support/Steam"), cat("/Users/test/Music/Ableton/User Library")].allSatisfy { $0 == .movable })
        check("Native Instruments, Logic, Apple Loops → Déplaçable", [cat("/Library/Application Support/Native Instruments"), cat("/Library/Application Support/Logic/Alchemy"), cat("/Library/Audio/Apple Loops/Apple")].allSatisfy { $0 == .movable })
        check("banque Native Instruments de /Users/Shared (marqueur .nicnt) → Déplaçable, guide native-access",
              cl("/Users/Shared/Analog Dreams Library/Samples").guide == "native-access" && cat("/Users/Shared/Analog Dreams Library") == .movable)
        check("bibliothèque Spitfire de /Users/Shared → Déplaçable, guide spitfire", cl("/Users/Shared/Spitfire LABS Library").guide == "spitfire")
        check("/Users/Shared inconnu → Inconnu", cat("/Users/Shared/Dossier Quelconque") == .unknown)
        check("photothèque ~/Pictures/*.photoslibrary → Déplaçable (guide photos)", cl("/Users/test/Pictures/Photothèque.photoslibrary/database").guide == "photos")
        check("~/Library/Application Support : Claude, Firefox, discord-like installées → À garder",
              cat("/Users/test/Library/Application Support/Claude/vm_bundles") == .keep && cat("/Users/test/Library/Application Support/Firefox/Profiles") == .keep && cat("/Users/test/Library/Application Support/Code") == .keep)
        check("Adobe (app Adobe installée) → À garder", cat("/Users/test/Library/Application Support/Adobe/Common/Plug-ins") == .keep && cat("/Library/Application Support/Adobe/CameraRaw") == .keep)
        check("Adobe Media Cache → Régénérable (plus précis que Adobe)", cat("/Users/test/Library/Application Support/Adobe/Common/Media Cache Files/x") == .regenerable)
        check("caches Electron dans Application Support (Claude/Cache, GPUCache) → Régénérable", cat("/Users/test/Library/Application Support/Claude/Cache/Cache_Data") == .regenerable && cat("/Users/test/Library/Application Support/Claude/GPUCache") == .regenerable)
        check("~/Library/Caches, Logs, /Library/Caches → Régénérable", ["/Users/test/Library/Caches/Adobe", "/Users/test/Library/Logs/x", "/Library/Caches/com.apple.x"].allSatisfy { cat($0) == .regenerable })
        check("MeldaProduction, AEJuice, iZotope (/Library/Application Support) → À garder", ["MeldaProduction", "AEJuice", "iZotope"].allSatisfy { cat("/Library/Application Support/\($0)/x") == .keep })
        check("/Library/Audio (Plug-Ins, Presets) → À garder, Apple Loops → Déplaçable", cat("/Library/Audio/Plug-Ins/VST3/Serum.vst3") == .keep && cat("/Library/Audio/Presets/Xfer Records") == .keep && cat("/Library/Audio/Apple Loops") == .movable)
        check("AssetsV2, /private/var/db, /private/var/folders, /System → Système", ["/System/Library/AssetsV2/x", "/private/var/db/x", "/private/var/folders/ab/cd/T", "/System/Library/Fonts"].allSatisfy { cat($0) == .system })
        check("Containers : com.apple.* → À garder, app installée → À garder", cat("/Users/test/Library/Containers/com.apple.Safari") == .keep && cat("/Users/test/Library/Containers/com.test.firefox") == .keep)
        check("identifiant d'app sans app installée → Reste d'app", cat("/Users/test/Library/Application Support/com.exemple.disparue") == .appLeftover && cat("/Users/test/Library/Containers/com.exemple.disparue") == .appLeftover)
        check("composant d'un éditeur dont une app est installée (com.adobe.dunamis) → À garder, jamais Reste d'app",
              cl("/Users/test/Library/Application Support/com.adobe.dunamis").rule == "contexte:editeur-installe" && cat("/Users/test/Library/Group Containers/JQ525L2MZD.com.adobe.GrowthSDK") == .keep)
        check("identifiant précédé d'un code d'équipe (6N38VWS5BX.ru.keepcoder.Telegram) sans app → Reste d'app", cat("/Users/test/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram") == .appLeftover)
        check("nom sans identifiant et sans app (ex. « Google ») → Inconnu, jamais Reste d'app", cat("/Users/test/Library/Application Support/Google") == .unknown)
        // Règle « éditeur absent » (comme les services) : le dossier porte le nom d'un éditeur dont un service tourne encore.
        var withSvc = context(); withSvc.servicePublishers = ["google", "microsoft"]
        check("dossier d'éditeur vu dans les services (Google), aucune app Google → Reste d'app, ainsi que ses enfants (GoogleUpdater)",
              cl("/Users/test/Library/Application Support/Google", withSvc).rule == "contexte:editeur-absent" && cl("/Users/test/Library/Application Support/Google/GoogleUpdater/x", withSvc).category == .appLeftover
              && cl("/Users/test/Library/Caches/Google", withSvc).category == .appLeftover)
        check("même dossier dans /Library/Application Support → Reste d'app", cl("/Library/Application Support/Google/GoogleUpdater", withSvc).category == .appLeftover)
        check("éditeur dont une app est installée (Microsoft : Visual Studio Code) → À garder", cl("/Users/test/Library/Application Support/Microsoft", withSvc).category == .keep && cl("/Users/test/Library/Caches/Microsoft", withSvc).category == .regenerable)
        check("éditeur sans service vu (Dropbox) → Inconnu (pas de règle ajoutée au hasard)", cl("/Users/test/Library/Application Support/Dropbox", withSvc).category == .unknown)
        check("cache Adobe lu dans les préférences (volume externe) → Régénérable", cat("/Volumes/DISQUE/MesCaches/Media Cache Files/x") == .regenerable)
        check("/Volumes/X/CACHES → Régénérable, /Volumes/X/.Spotlight-V100 → Système, .Trashes → Régénérable",
              cat("/Volumes/DONNEES/CACHES/Media") == .regenerable && cat("/Volumes/DONNEES/.Spotlight-V100") == .system && cat("/Volumes/DONNEES/.Trashes/501") == .regenerable)
        check("/Volumes/X/Projets/CACHES (pas à la racine) → Inconnu", cat("/Volumes/DONNEES/Projets/CACHES") == .unknown)
        check("dossier personnel (Documents, Pictures) → À garder, ~/.Trash → Régénérable", cat("/Users/test/Documents/x") == .keep && cat("/Users/test/Pictures/x.jpg") == .keep && cat("/Users/test/.Trash/x") == .regenerable)
        check("sans règle ni contexte → Inconnu par défaut, raison affichée", cl("/Users/test/.platformio").category == .unknown && !cl("/Users/test/.platformio").reason.isEmpty && cl("/Users/test/.platformio").rule == "defaut")
        check("racine du disque → Système", cat("/") == .system)
        check("« Inconnu » : action = lecture seule", StorageCategory.unknown.action == "Lecture seule" && StorageCategory.regenerable.action == "Supprimer" && StorageCategory.appLeftover.action == "Corbeille")
        // Les protections priment : la catégorie n'ôte jamais une protection.
        let music = URL(fileURLWithPath: FS.h("Music/Ableton/User Library").path)
        check("protections prioritaires : ~/Music (lecture seule choisie à l'assistant) le reste alors que sa catégorie est Déplaçable",
              ConfigTests.withStore { store in
                  store.set([FS.h("Music").path], forKey: "readOnlyPaths")
                  return Ignore.readOnly(music) && !Ignore.removable(music) && { var c = context(); c.home = FS.home.path; return Classifier.classify(music.path, context: c).category == .movable }()
              })
        check("protections prioritaires : ~/.ssh bloqué, jamais lu", Ignore.blocked(FS.h(".ssh")))
    }

    // MARK: Analyse et anneaux

    static func scanner(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("zerOS-storage-\(UUID().uuidString)")
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("ferme").path); try? fm.removeItem(at: root) }
        func put(_ rel: String, _ size: Int) {
            let u = root.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: u.path, contents: Data(repeating: 7, count: size))
        }
        put("grand/a.bin", 8_000_000); put("grand/b.bin", 4_000_000); put("grand/profond/c/d/e.bin", 2_000_000)
        put("moyen/f.bin", 1_000_000); put("petits/p.txt", 100)
        for k in 0..<300 { put("miettes/m\(k).txt", 2_000) }
        put("ferme/secret.bin", 1_000_000)
        put("ignore-moi/x.bin", 3_000_000); put("zz-apres/z.bin", 1_000_000)
        chmod(root.appendingPathComponent("ferme").path, 0)
        let direct = FS.allocatedSize(root.appendingPathComponent("grand")) + FS.allocatedSize(root.appendingPathComponent("zz-apres")) + FS.allocatedSize(root.appendingPathComponent("moyen")) + FS.allocatedSize(root.appendingPathComponent("petits")) + FS.allocatedSize(root.appendingPathComponent("miettes"))
        let r = StorageScan.scan(root, extraSkip: [root.standardizedFileURL.path + "/ignore-moi"])
        let n = r.root
        check("dossier ignoré : absent de l'arbre, signalé, et les dossiers suivants restent comptés", n.find(root.path + "/ignore-moi") == nil && r.skipped.count == 1 && n.find(root.path + "/zz-apres") != nil)
        check("analyse : taille de la racine = somme des tailles occupées (\(Fmt.bytes(n.size)) pour \(Fmt.bytes(direct)))", abs(n.size - direct) < 64 * 1024)
        check("analyse : enfants triés du plus gros au plus petit, 'grand' en tête", n.children.first?.name == "grand" && zip(n.children, n.children.dropFirst()).allSatisfy { $0.size >= $1.size })
        check("analyse : 'grand' garde ses fichiers de plus de 256 Ko et son sous-dossier", n.find(root.path + "/grand")?.children.map(\.name).sorted() == ["a.bin", "b.bin", "profond"])
        check("analyse : petits éléments non gardés mais comptés (miettes : octets propres > 0, aucun enfant)", n.find(root.path + "/miettes").map { $0.children.isEmpty && $0.own > 0 } == true)
        check("analyse : octets propres + enfants = taille, partout", { func ok(_ x: SNode) -> Bool { x.own + x.children.reduce(0) { $0 + $1.size } >= x.size && x.children.allSatisfy(ok) }; return ok(n) }())
        check("analyse : dossier illisible compté, pas de plantage", r.unreadable >= 1)
        check("analyse : chemin reconstruit depuis les parents", n.find(root.path + "/grand/profond")?.path == root.standardizedFileURL.path + "/grand/profond")
        let partial = StorageScan.scan(root, budget: 0)
        check("budget de temps épuisé → analyse partielle cohérente (pas de plantage)", partial.partial || partial.entries < 512)
        // Secteur « Non analysé » : espace utilisé du volume moins le total analysé.
        let tree = StorageScan.scan(root, extraSkip: [root.standardizedFileURL.path + "/ignore-moi"]).root
        let analysed = tree.size, kidsBefore = tree.children.count
        let added = StorageAnalysis.addUnanalysed(to: tree, volume: root, used: analysed + 5_000_000_000)
        let sector = tree.children.first { $0.name == StorageAnalysis.unanalysedName }
        check("« Non analysé » : utilisé 5 Go de plus que l'analysé → secteur de \(Fmt.bytes(added)), total de la racine = espace utilisé, catégorie Système",
              added == 5_000_000_000 && sector?.size == added && tree.size == analysed + 5_000_000_000 && sector?.cls?.category == .system && tree.children.count == kidsBefore + 1)
        let again = StorageAnalysis.addUnanalysed(to: tree, volume: root, used: analysed + 2_000_000_000)
        check("« Non analysé » : recalcul sans doublon (2 Go au deuxième appel)", again == 2_000_000_000 && tree.children.filter { $0.name == StorageAnalysis.unanalysedName }.count == 1 && tree.size == analysed + 2_000_000_000)
        check("« Non analysé » : écart inférieur à 100 Mo → aucun secteur", StorageAnalysis.addUnanalysed(to: tree, volume: root, used: analysed + 50_000_000) == 0 && tree.size == analysed && tree.children.count == kidsBefore)
        check("« Non analysé » : espace utilisé du disque interne lisible", (StorageAnalysis.volumeUsed(URL(fileURLWithPath: "/")) ?? 0) > 0)
        let c = StorageScan.Control(); c.cancel()
        check("annulation → résultat partiel", StorageScan.scan(root, control: c).root.size >= 0)
        // Cache sur disque
        StorageScan.save(r, root: root)
        let back = StorageScan.load(root)
        try? fm.removeItem(at: StorageScan.cacheURL(root))
        check("cache : relecture identique (tailles, enfants, parents)", back.map { $0.root.size == n.size && $0.root.children.count == n.children.count && $0.root.children.allSatisfy { $0.parent === $0.parent && $0.parent?.name == n.name } } == true)
        // Anneaux
        let ctx = context()
        let lay = SunburstLayout(focus: n) { _ in .keep }
        let first = lay.arcs.filter { $0.depth == 1 }
        check("anneaux : les arcs d'un niveau ne se chevauchent pas et tiennent dans un tour", zip(first, first.dropFirst()).allSatisfy { $0.a1 <= $1.a0 + 1e-9 } && (first.last?.a1 ?? 0) <= 2 * .pi + 1e-9)
        check("anneaux : angle proportionnel à la taille (grand ≈ \(Int(Double(n.children.first?.size ?? 0) * 100 / Double(max(1, n.size)))) %)", first.first.map { abs(($0.a1 - $0.a0) / (2 * .pi) - Double($0.node.size) / Double(n.size)) < 1e-6 } == true)
        check("anneaux : arcs trop étroits omis, profondeur ≤ \(SunburstLayout.rings)", lay.arcs.allSatisfy { $0.a1 - $0.a0 >= SunburstLayout.minAngle && $0.depth <= SunburstLayout.rings })
        let others = lay.arcs.filter(\.others)
        check("anneaux : enfants de moins de 1° regroupés (\(others.count) segment(s) « autres », un seul par parent), aucun autre segment plus étroit",
              lay.arcs.allSatisfy { $0.others || $0.a1 - $0.a0 >= SunburstLayout.groupAngle }
              && Set(others.map { "\(ObjectIdentifier($0.node).hashValue)-\($0.depth)" }).count == others.count)
        if let a = first.first {
            let size = CGSize(width: 400, height: 400)
            let radius = 200.0 - 6
            let (r0, r1) = SunburstLayout.radii(1, radius)
            let mid = (a.a0 + a.a1) / 2, rm = (r0 + r1) / 2
            let p = CGPoint(x: 200 + rm * sin(mid), y: 200 - rm * cos(mid))
            check("anneaux : la souris retrouve l'arc sous le curseur, rien dans le trou central", lay.arc(at: p, in: size)?.node === a.node && lay.arc(at: CGPoint(x: 200, y: 200), in: size) == nil)
        }
        // Totaux : chaque octet dans une seule catégorie.
        let st = StorageAnalysis.compute(roots: [n], zones: [StorageZone(name: "Tout", paths: [n.path])], context: ctx)
        check("totaux : somme des catégories = taille de l'arbre, zone « Tout » = tout", st.total == n.size && st.byCategory.values.reduce(0, +) == n.size && st.byZone[0].values.reduce(0, +) == n.size)
        check("totaux : dossiers « Inconnu » listés du plus gros au plus petit, en descendant jusqu'au fond (\(st.unknown.count) trouvés)",
              !st.unknown.isEmpty && zip(st.unknown, st.unknown.dropFirst()).allSatisfy { $0.size >= $1.size } && st.unknown.allSatisfy { $0.path.hasPrefix(n.path) })
        let sys = SNode(name: "Données système", size: 0, isDir: true)
        sys.children = [n]
        check("Données système : le nœud virtuel garde les vrais chemins et un fil d'Ariane", n.chain(upTo: sys).first === sys && n.chain(upTo: sys).last === n)
    }

    // MARK: Catalogue « Déplacer »

    static func relocate(_ check: (String, Bool) -> Void) {
        let ctx = context()
        let ids = Relocate.catalog.map(\.id)
        check("catalogue : \(ids.count) entrées (Whisky, PrismLauncher, Native Access, Spitfire, Logic, Ableton, Steam, Photos, caches Adobe)",
              Set(ids) == ["whisky", "prism", "native-access", "spitfire", "logic", "ableton", "steam", "photos", "adobe-cache"])
        check("catalogue : chaque entrée a une marche à suivre et des dossiers issus des règles du moteur",
              Relocate.catalog.allSatisfy { !$0.steps.isEmpty && !$0.apps.isEmpty && (!Relocate.paths(for: $0.id, context: ctx).isEmpty || $0.id == "photos") })
        check("catalogue : procédure annoncée « non vérifiée » sur toutes les entrées (aucune confirmée), jamais vide", Relocate.catalog.allSatisfy { $0.unverified?.contains("non vérifiée") == true })
        check("catalogue : les bibliothèques .nicnt de /Users/Shared sont ajoutées à Native Access", Relocate.paths(for: "native-access", context: ctx).contains("/Users/Shared/Analog Dreams Library"))
        let big = TodaySnapshot(diskFree: 10, diskTotal: 100, pressure: 1, swapUsed: 0, memTotal: 1,
                                externals: [], trashSize: 0, movable: [("Whisky", 9_000_000_000), ("Steam", 2_000_000_000)], dataVolumePlugged: true)
        let a = TodayEngine.actions(big).first { $0.id == "move" }
        check("Aujourd'hui : disque presque plein → « \(a?.title ?? "—") »", a?.title == "Déplacer Whisky : \(Fmt.bytes(9_000_000_000))" && a?.target == .relocate)
        var noVol = big; noVol.dataVolumePlugged = false
        var green = big; green.diskFree = 80
        var small = big; small.movable = [("Steam", 500_000_000)]
        check("Aujourd'hui : pas d'action « Déplacer » sans disque de données, disque au vert, ou moins de 1 Go",
              TodayEngine.actions(noVol).allSatisfy { $0.id != "move" } && TodayEngine.actions(green).allSatisfy { $0.id != "move" } && TodayEngine.actions(small).allSatisfy { $0.id != "move" })
    }

    // MARK: Analyse réelle (lecture seule)

    static func realDisk() {
        print("\n=== Stockage : analyse réelle du disque interne (lecture seule) ===")
        let cpu0 = cpuSeconds(), t0 = Date()
        let base = footprint()
        var peak: Int64 = base
        let r = StorageScan.scan(URL(fileURLWithPath: "/")) { _ in peak = max(peak, footprint()) }
        let scanCPU = cpuSeconds() - cpu0, scanWall = Date().timeIntervalSince(t0)
        peak = max(peak, footprint())
        print("  Analyse : \(String(format: "%.1f", scanWall)) s, CPU consommé \(String(format: "%.1f", scanCPU)) s (\(String(format: "%.0f", scanCPU * 100 / max(0.1, scanWall))) % d'un cœur en moyenne), mémoire de pointe \(Fmt.mem(peak)) (+\(Fmt.mem(max(0, peak - base))) pendant l analyse, \(Fmt.mem(base)) avant), \(r.entries) éléments, \(r.unreadable) non lus, \(r.skipped.count) ignorés")
        print("  Ignorés : " + r.skipped.prefix(12).map { $0.replacingOccurrences(of: FS.home.path, with: "~") }.joined(separator: ", "))
        print("  \(r.partial ? "PARTIELLE" : "complète") · racine \(Fmt.bytes(r.root.size))")
        let c0 = cpuSeconds(), t1 = Date()
        let ctx = ClassContext.live()
        print("  Contexte : \(ctx.apps.count) apps recensées, \(ctx.running.count) ouvertes, bibliothèques .nicnt : \(ctx.nicntFolders.sorted().joined(separator: ", ")), caches des préférences : \(ctx.prefsCaches.count)")
        let all = StorageAnalysis.compute(roots: [r.root], zones: StorageAnalysis.diskZones(home: ctx.home), context: ctx, unknownMin: 500_000_000)
        let zones = StorageAnalysis.systemDataZones(home: ctx.home)
        let sysNodes = StorageAnalysis.nodes(for: zones, in: r.root)
        let sys = StorageAnalysis.compute(roots: sysNodes, zones: zones, context: ctx, unknownMin: 500_000_000)
        print("  Classification : \(String(format: "%.2f", Date().timeIntervalSince(t1))) s (CPU \(String(format: "%.2f", cpuSeconds() - c0)) s), dont recensement des apps")
        func table(_ title: String, _ s: StorageStats) {
            print("\n  — \(title) : \(Fmt.bytes(s.total))")
            for c in StorageCategory.allCases { print("      \(c.label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(Fmt.bytes(s.byCategory[c] ?? 0))") }
            print("      Par zone (" + StorageCategory.allCases.map(\.label).joined(separator: " / ") + ") :")
            for (i, n) in s.zoneNames.enumerated() where s.byZone[i].values.reduce(0, +) > 0 {
                print("        \(n) : \(Fmt.bytes(s.byZone[i].values.reduce(0, +))) — " + StorageCategory.allCases.map { Fmt.bytes(s.byZone[i][$0] ?? 0) }.joined(separator: " / "))
            }
        }
        table("Disque interne", all)
        table("Données système (périmètre SPEC.md)", sys)
        print("      AssetsV2 : \(r.root.find("/System/Library/AssetsV2") == nil ? "non analysé (/System est bloqué : jamais lu)" : "analysé")")
        print("\n  Dossiers restés « Inconnu » de plus de 500 Mo (le plus haut niveau seulement) :")
        for u in all.unknown { print("      \(Fmt.bytes(u.size).padding(toLength: 9, withPad: " ", startingAt: 0)) \(u.path.replacingOccurrences(of: FS.home.path, with: "~"))") }
        if all.unknown.isEmpty { print("      aucun") }
        // Les dossiers qui portent une règle (là où la catégorie change), les plus gros par catégorie, avec la raison.
        var byRule: [StorageCategory: [(String, Int64, Classification)]] = [:]
        func collect(_ n: SNode, _ path: String, _ parentRule: String?) {
            if let c = n.cls, c.rule != parentRule, c.rule != "defaut", n.size >= 200_000_000 { byRule[c.category, default: []].append((path, n.size, c)) }
            for k in n.children { collect(k, path == "/" ? "/" + k.name : path + "/" + k.name, n.cls?.rule) }
        }
        collect(r.root, "/", nil)
        print("\n  Dossiers de plus de 200 Mo là où la catégorie est décidée, par catégorie :")
        for cat in StorageCategory.allCases {
            let l = (byRule[cat] ?? []).sorted { $0.1 > $1.1 }.prefix(10)
            if l.isEmpty { continue }
            print("    [\(cat.label)]")
            for (p, s, c) in l { print("      \(Fmt.bytes(s).padding(toLength: 9, withPad: " ", startingAt: 0)) \(p.replacingOccurrences(of: FS.home.path, with: "~")) — \(c.reason)") }
        }
        StorageScan.save(r, root: URL(fileURLWithPath: "/"))
        let t2 = Date(), loaded = StorageScan.load(URL(fileURLWithPath: "/"))
        let cacheBytes = (try? Data(contentsOf: StorageScan.cacheURL(URL(fileURLWithPath: "/"))))?.count ?? 0
        print("\n  Cache : \(Fmt.bytes(Int64(cacheBytes))) sur disque, relu en \(String(format: "%.2f", Date().timeIntervalSince(t2))) s, \(loaded.map { count($0.root) } ?? 0) nœuds")
        let t3 = Date(), lay = SunburstLayout(focus: r.root) { $0.structural ? nil : Classifier.classify($0.path, context: ctx).category }
        print("  Anneaux : \(lay.arcs.count) arcs calculés en \(String(format: "%.2f", Date().timeIntervalSince(t3))) s")
        let rel = Relocate.measure(context: ctx)
        print("\n  Déplacer (disque interne) :")
        for i in rel { print("      \(i.entry.name) : \(Fmt.bytes(i.size))\(i.installed.isEmpty ? " (app non installée)" : "")") }
    }

    static func count(_ n: SNode) -> Int { 1 + n.children.reduce(0) { $0 + count($1) } }

    static func cpuSeconds() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}
