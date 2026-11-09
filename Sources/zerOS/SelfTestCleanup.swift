import Foundation

/// Sécurité du nettoyage (SECURITE-NETTOYAGE.md), chaque règle prouvée : la règle 1.0 sur les vrais résultats d'analyse (lecture seule),
/// puis de vraies suppressions, mises à la Corbeille et vidages de corbeille sur une image disque temporaire (/tmp/zerOS-test-…, montée
/// comme un disque externe) : rien d'autre n'est touché. Le journal « mis à la Corbeille » est remplacé par un fichier temporaire.
enum CleanupSafetyTests {
    static func run() async {
        print("\n=== Sécurité du nettoyage (règle 1.0, Corbeille, vidage de corbeille) ===")
        var fails = 0
        func check(_ name: String, _ ok: Bool) { print("  \(ok ? "✓" : "✗") \(name)"); if !ok { fails += 1 } }

        // 1. Règle sur des groupes synthétiques.
        let kinds: [RemovalMode] = [.delete, .emptyDir, .admin, .adminEmpty, .custom("prefsCache"), .trash, .adminTrash, .custom("evict")]
        let items = kinds.map { CleanItem(url: URL(fileURLWithPath: "/tmp/x"), title: "x", mode: $0, preselected: true) }
        let user = CleanGroup(id: "u", title: "u", items: items).protected().items
        check("groupe de fichiers de l'utilisateur : définitif → Corbeille (fichier, dossier, système), action définitive sans équivalent → analyse seule",
              user.map(\.mode) == [.trash, .trash, .adminTrash, .adminTrash, .none, .trash, .adminTrash, .custom("evict")])
        check("groupe de fichiers de l'utilisateur : rien de présélectionné", !user.contains { $0.preselected })
        let regen = CleanGroup(id: "r", title: "r", items: items, regenerable: true).protected().items
        check("groupe régénérable : modes et présélection inchangés", regen.map(\.mode) == kinds && regen.allSatisfy(\.preselected))

        // 2. Vrais résultats d'analyse (lecture seule) : chaque élément respecte la règle après `protected()`.
        let rep = Reporter.silent
        var groups = await Junk.scanAll(rep) + CacheScan.scan(rep) + [MailJunk.scan()] + AIClutter.scan()
        groups += await AppCatalog.leftovers(rep) + AppCatalog.installers(rep) + Clutter.downloads(rep) + Clutter.largeOld(rep) + CloudCleanup.scan(rep)
        let shown = groups.map { $0.protected() }
        let all = shown.flatMap { g in g.items.map { (g, $0) } }
        let badDefinitive = all.filter { g, i in CleanGroup.isDefinitive(i.mode) && !g.regenerable }
        let badPreselect = all.filter { g, i in i.preselected && !g.regenerable }
        print("  \(shown.count) groupes analysés, \(all.count) éléments ; régénérables : " + Set(shown.filter(\.regenerable).map(\.id)).sorted().joined(separator: ", "))
        check("aucune suppression définitive hors caches et fichiers recréés seuls (\(badDefinitive.count) écart)", badDefinitive.isEmpty)
        check("rien de présélectionné hors caches régénérables (\(badPreselect.count) écart)", badPreselect.isEmpty)
        check("« Corbeilles » n'est plus dans le nettoyage, ni « vider » en action d'élément", !shown.contains { $0.id == "trash" } && !all.contains { $0.1.mode == .custom("emptyTrash") })
        check("versions de documents : analyse seule", shown.first { $0.id == "docVersions" }.map { $0.infoOnly && $0.items.allSatisfy { $0.mode == .none } } ?? true)
        check("pièces jointes Mail, réglages abîmés, lanceurs cassés, comptes supprimés : Corbeille, rien coché",
              shown.filter { ["mail", "brokenPrefs", "brokenLogin", "deletedUsers"].contains($0.id) }.flatMap(\.items).allSatisfy { ($0.mode == .trash || $0.mode == .adminTrash) && !$0.preselected })
        if let app = AppCatalog.appURLs().lazy.compactMap({ AppCatalog.info($0, withSize: false) }).first(where: { $0.bundleID != nil }) {
            let rel = AppCatalog.relatedFiles(for: app)
            check("désinstallation (\(app.name), \(rel.count) fichier(s) lié(s)) : tout à la Corbeille, seuls caches et états cochés",
                  rel.allSatisfy { f in (f.mode == .trash || f.mode == .adminTrash) && (!f.preselected || AppCatalog.regenerableDirs.contains { f.subtitle.hasSuffix($0) }) })
        }
        let cmd = FS.adminTrashCommand(URL(fileURLWithPath: "/Library/LaunchDaemons/com.exemple.zt.plist"))
        check("élément système : commande administrateur = déplacement vers ~/.Trash, sans « rm » (\(cmd))",
              cmd.hasPrefix("mv -n -- ") && cmd.contains(FS.h(".Trash").path) && !cmd.contains("rm "))

        // 3. Image disque temporaire montée comme un disque externe.
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/zerOS-test-securite-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: root); try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let oldLog = TrashLog.file
        TrashLog.file = root.appendingPathComponent("mis-a-la-corbeille.json")
        defer { TrashLog.file = oldLog; try? fm.removeItem(at: root) }
        let name = "ZT SECU \(ProcessInfo.processInfo.processIdentifier % 10000)"
        guard let img = DiskImage.makeExternal(root, name, mb: 40) else { check("image disque temporaire créée", false); return }
        defer { DiskImage.detach(img) }
        let v = img.mount
        func mk(_ rel: String, _ bytes: Int = 4096) { let u = v.appendingPathComponent(rel); try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); fm.createFile(atPath: u.path, contents: Data(count: bytes)) }
        func ex(_ rel: String) -> Bool { fm.fileExists(atPath: v.appendingPathComponent(rel).path) }
        mk("Caches/App/a.cache"); mk("Caches/App/sous/b.cache"); mk("Caches/App/Morceau.logicx/Alternatives/000/ProjectData")
        mk("Caches/App/Garde/notes.txt")
        // Dossier de caches (chemin « /Data/Library/Caches/ » : son contenu n'est pas inspecté d'avance) : chaque élément est vérifié.
        mk("Data/Library/Caches/App/a.cache"); mk("Data/Library/Caches/App/sous/b.cache"); mk("Data/Library/Caches/App/Morceau.logicx/Alternatives/000/ProjectData")
        mk("Data/Library/Caches/App/Garde/notes.txt"); mk("Docs/rapport.pdf", 200_000); mk("Docs/photo.jpg", 300_000); mk("Docs/Album.logicx/ProjectData")
        mk("Perso/lettre.txt")
        let trashDir = v.appendingPathComponent(".Trashes/\(getuid())")
        ConfigTests.withStore { _ in
            Ignore.addReadOnly(v.appendingPathComponent("Caches/App/Garde").path)
            Ignore.addReadOnly(v.appendingPathComponent("Data/Library/Caches/App/Garde").path)
            Ignore.addReadOnly(v.appendingPathComponent("Perso").path)

            // Vider un dossier ordinaire qui contient un projet : refusé en entier, rien supprimé.
            let e0 = FS.emptyDirectory(v.appendingPathComponent("Caches/App"))
            check("vider un dossier qui contient un projet : refusé en bloc, rien supprimé (\(e0.protected.first ?? "—"))",
                  e0.removed == 0 && ex("Caches/App/a.cache") && ex("Caches/App/Morceau.logicx/Alternatives/000/ProjectData"))
            // Vider un dossier de caches : chaque élément contenu est vérifié.
            let e = FS.emptyDirectory(v.appendingPathComponent("Data/Library/Caches/App"))
            check("vider un dossier de caches : caches supprimés (\(e.removed)), projet et dossier en lecture seule contenus laissés (\(e.protected.count))",
                  !ex("Data/Library/Caches/App/a.cache") && !ex("Data/Library/Caches/App/sous") && ex("Data/Library/Caches/App/Morceau.logicx/Alternatives/000/ProjectData")
                  && ex("Data/Library/Caches/App/Garde/notes.txt") && ex("Data/Library/Caches/App") && e.removed == 2 && e.protected.count == 2)

            // Fichiers de l'utilisateur : Corbeille du disque, récupérables.
            let r1 = runSync { await Cleaner.perform([CleanItem(url: v.appendingPathComponent("Docs/rapport.pdf"), title: "rapport.pdf", size: 200_000, mode: .trash)], report: .silent) }
            check("fichier de l'utilisateur → Corbeille du disque (récupérable : \(trashDir.path.replacingOccurrences(of: v.path, with: "…"))/rapport.pdf)",
                  r1.count == 1 && !ex("Docs/rapport.pdf") && fm.fileExists(atPath: trashDir.appendingPathComponent("rapport.pdf").path))
            // Bouton qui imposerait « supprimer » sur un groupe de fichiers de l'utilisateur : la règle le ramène à la Corbeille.
            let forced = CleanGroup.policy(CleanItem(url: v.appendingPathComponent("Docs/photo.jpg"), title: "photo.jpg", size: 300_000, mode: .delete), regenerable: false)
            let plan = CleanPlan.summary([forced])
            _ = runSync { await Cleaner.perform([forced], report: .silent) }
            check("« supprimer » imposé sur un fichier de l'utilisateur → Corbeille quand même", !ex("Docs/photo.jpg") && fm.fileExists(atPath: trashDir.appendingPathComponent("photo.jpg").path))
            check("confirmation : nombre, taille, façon de supprimer, éléments (« \(plan.replacingOccurrences(of: "\n", with: " / ")) »)",
                  plan.contains("À la Corbeille (récupérable) : 1 élément") && plan.contains("photo.jpg") && !plan.contains("définitivement"))
            // Dossier qui contient un projet, dossier en lecture seule : refusés même en suppression directe.
            let r2 = runSync { await Cleaner.perform([CleanItem(url: v.appendingPathComponent("Docs"), title: "Docs", mode: .delete),
                                                     CleanItem(url: v.appendingPathComponent("Perso/lettre.txt"), title: "lettre.txt", mode: .delete)], report: .silent) }
            check("dossier contenant un projet et fichier en lecture seule : refusés, intacts (\(r2.errors.count) refus)",
                  r2.count == 0 && r2.errors.count == 2 && ex("Docs/Album.logicx/ProjectData") && ex("Perso/lettre.txt"))
            let ro = CleanGroup(id: "ro", title: "ro", items: [CleanItem(url: v.appendingPathComponent("Perso/lettre.txt"), title: "lettre", mode: .trash, preselected: true)]).protected()
            check("lecture seule : affiché 🔒, ni coché ni sélectionnable", ro.items[0].readOnly && !ro.items[0].preselected && !ro.items[0].actionable)
        }

        // 4. « Vider la Corbeille » : corbeille de l'utilisateur sur ce disque, éléments verrouillés laissés et signalés.
        mk(".Trashes/\(getuid())/verrouille.txt"); mk(".Trashes/\(getuid())/Dossier/dedans-verrouille.txt"); mk(".Trashes/\(getuid())/Dossier/libre.txt")
        Shell.run("/usr/bin/chflags", ["uchg", trashDir.appendingPathComponent("verrouille.txt").path, trashDir.appendingPathComponent("Dossier/dedans-verrouille.txt").path])
        let bin = TrashBins.bins().first { $0.url.standardizedFileURL.path == trashDir.standardizedFileURL.path }
        check("corbeille du disque externe listée à part : « \(bin?.title ?? "—") », \(bin?.count ?? 0) éléments, dont \(bin?.recent ?? 0) mis par zerOS depuis 24 h",
              bin?.title == "Corbeille de « \(name) »" && bin?.count == 4 && bin?.recent == 2)
        let text = bin.map(TrashBins.confirmation) ?? ""
        check("confirmation : nombre, taille, mention « irréversible », éléments mis par zerOS depuis 24 h",
              text.contains("4 éléments") && text.contains("Irréversible") && text.contains("dont 2 éléments mis à la Corbeille par zerOS depuis 24 h"))
        let er = TrashBins.empty(trashDir)
        check("vidage : 2 supprimés, verrouillé et dossier contenant un verrouillé laissés et signalés (\(er.left.joined(separator: " ; ")))",
              er.removed == 2 && er.left.count == 2 && er.left.allSatisfy { $0.contains("verrouillé") }
              && fm.fileExists(atPath: trashDir.appendingPathComponent("verrouille.txt").path) && fm.fileExists(atPath: trashDir.appendingPathComponent("Dossier/libre.txt").path))
        let notBin = TrashBins.empty(v.appendingPathComponent("Docs"))
        check("vidage refusé sur un dossier qui n'est pas une corbeille", notBin.removed == 0 && ex("Docs/Album.logicx/ProjectData"))
        Shell.run("/usr/bin/chflags", ["-R", "nouchg", trashDir.path])
        print(fails == 0 ? "  Tout est bon." : "  \(fails) échec(s).")
    }

    /// Attend une tâche asynchrone depuis le fil de l'autotest.
    static func runSync<T: Sendable>(_ f: @escaping @Sendable () async -> T) -> T {
        let box = SyncBox<T>(), sem = DispatchSemaphore(value: 0)
        Task.detached { box.v = await f(); sem.signal() }
        sem.wait()
        return box.v!
    }
}

final class SyncBox<T>: @unchecked Sendable { var v: T? }
