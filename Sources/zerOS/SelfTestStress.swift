import Foundation

/// Situations dures (explicite : `--selftest stress`, jamais par défaut) : analyse de Stockage pendant qu'un volume factice disparaît,
/// dossier de plus de 500 000 fichiers (durée, budget, annulation, mémoire), deux analyses en même temps, dossier illisible.
/// Tout se passe dans des images disque temporaires ; rien de réel n'est lu en dehors du disque interne déjà analysé par `storage`.
enum StressTests {
    static var fails = 0
    static func check(_ name: String, _ ok: Bool) { print("  \(ok ? "✓" : "✗") \(name)"); if !ok { fails += 1 } }
    static func rssMo() -> Int {
        var info = mach_task_basic_info(); var n = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &n) } }
        return r == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : 0
    }

    /// Crée `dirs` dossiers de `perDir` fichiers vides dans `root` (python3 : bien plus rapide que FileManager).
    static func populate(_ root: URL, dirs: Int, perDir: Int) -> Bool {
        let code = "import os,sys\nr=sys.argv[1]\nfor d in range(int(sys.argv[2])):\n p=os.path.join(r,'d%05d'%d); os.makedirs(p)\n for f in range(int(sys.argv[3])): os.close(os.open(os.path.join(p,'f%d'%f), os.O_CREAT|os.O_WRONLY))\n"
        return Shell.run("/usr/bin/python3", ["-I", "-c", code, root.path, "\(dirs)", "\(perDir)"], timeout: 900).ok
    }

    static func run() {
        fails = 0
        print("\n=== Situations dures (images disque temporaires) ===")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("zerOS-stress-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        unreadable(root)
        hugeFolder(root)
        volumeVanishes(root)
        print(fails == 0 ? "  Tout est bon." : "  \(fails) échec(s).")
    }

    // MARK: Dossier illisible : compté, et les dossiers suivants ne sont pas perdus

    static func unreadable(_ root: URL) {
        print("— Dossier illisible (accès refusé)")
        let fm = FileManager.default
        let t = root.appendingPathComponent("illisible")
        for d in ["a", "b-interdit", "c"] {
            try? fm.createDirectory(at: t.appendingPathComponent(d), withIntermediateDirectories: true)
            fm.createFile(atPath: t.appendingPathComponent("\(d)/gros.bin").path, contents: Data(count: 2_000_000))
        }
        chmod(t.appendingPathComponent("b-interdit").path, 0)
        defer { chmod(t.appendingPathComponent("b-interdit").path, 0o755) }
        let r = StorageScan.scan(t)
        let names = Set(r.root.children.map(\.name))
        check("dossier interdit compté (\(r.unreadable)), dossiers voisins gardés (\(names.sorted()))", r.unreadable >= 1 && names.contains("a") && names.contains("c") && !r.partial)
    }

    // MARK: Plus de 500 000 fichiers

    static func hugeFolder(_ root: URL) {
        print("— Dossier énorme (520 000 fichiers factices)")
        guard let img = DiskImage.make(root, "ENORME", fs: "APFS", mb: 1500) else { check("image disque ENORME créée", false); return }
        defer { DiskImage.detach(img) }
        let t0 = Date()
        guard populate(img.mount, dirs: 520, perDir: 1000) else { check("création des 520 000 fichiers", false); return }
        print("  (création : \(String(format: "%.0f", Date().timeIntervalSince(t0))) s)")
        let r0 = rssMo()
        let r = StorageScan.scan(img.mount)
        let r1 = rssMo()
        check("analyse complète : \(r.entries) éléments en \(String(format: "%.1f", r.seconds)) s, non partielle", !r.partial && r.entries > 520_000)
        check("mémoire : \(r0) → \(r1) Mo (arbre élagué, moins de 150 Mo de plus)", r1 - r0 < 150)
        check("arbre élagué : \(r.root.children.count) enfants à la racine (≤ \(StorageScan.maxKids))", r.root.children.count <= StorageScan.maxKids)
        // Budget : s'arrête vite avec un résultat cohérent
        let b = StorageScan.scan(img.mount, budget: 1.0)
        check("budget 1 s : partiel, rendu en \(String(format: "%.1f", b.seconds)) s", b.partial && b.seconds < 4)
        // Annulation en cours de route
        let c = StorageScan.Control()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { c.cancel() }
        let cancelled = StorageScan.scan(img.mount, control: c)
        check("annulation après 0,5 s : partielle, rendue en \(String(format: "%.1f", cancelled.seconds)) s", cancelled.partial && cancelled.seconds < 4)
        // Deux analyses en même temps
        var a: StorageScan.Result?, bb: StorageScan.Result?
        let g = DispatchGroup()
        let t = Date()
        for i in 0..<2 { g.enter(); DispatchQueue.global().async { let x = StorageScan.scan(img.mount); if i == 0 { a = x } else { bb = x }; g.leave() } }
        let done = g.wait(timeout: .now() + 300) == .success
        check("deux analyses simultanées : terminées en \(String(format: "%.1f", Date().timeIntervalSince(t))) s, mêmes résultats (\(a?.entries ?? 0) / \(bb?.entries ?? 0))",
              done && a?.entries == bb?.entries && a?.root.size == bb?.root.size && a?.partial == false)
        // Cache : écriture et relecture de l'arbre énorme
        StorageScan.save(r, root: img.mount)
        let back = StorageScan.load(img.mount)
        check("cache écrit puis relu (\(back?.info.entries ?? 0) éléments)", back?.info.entries == r.entries)
        try? FileManager.default.removeItem(at: StorageScan.cacheURL(img.mount))
    }

    // MARK: Volume retiré pendant l'analyse

    static func volumeVanishes(_ root: URL) {
        print("— Volume factice débranché pendant l'analyse")
        guard let img = DiskImage.make(root, "DISPARU", fs: "APFS", mb: 1200) else { check("image disque DISPARU créée", false); return }
        var detached = false
        defer { if !detached { DiskImage.detach(img) } }
        guard populate(img.mount, dirs: 400, perDir: 1000) else { check("création des 400 000 fichiers", false); return }
        let t0 = Date()
        var cut: Date?
        let r = StorageScan.scan(img.mount) { p in
            if cut == nil, p.entries > 20_000 {
                cut = Date(); detached = true
                DispatchQueue.global().async { DiskImage.detach(img) }
            }
        }
        let secs = Date().timeIntervalSince(t0)
        print("  (coupé après \(String(format: "%.1f", cut.map { $0.timeIntervalSince(t0) } ?? -1)) s ; analyse terminée à \(String(format: "%.1f", secs)) s : \(r.entries) éléments, partielle \(r.partial), illisibles \(r.unreadable))")
        check("l'analyse se termine sans blocage ni plantage (< 60 s)", cut != nil && secs < 60)
        check("la racine rendue est cohérente (taille ≥ 0, enfants ≤ \(StorageScan.maxKids))", r.root.size >= 0 && r.root.children.count <= StorageScan.maxKids)
        check("volume perdu détecté : résultat marqué partiel (\(r.volumeLost)/\(r.partial)), arrêt avant la fin des 400 000 fichiers", r.volumeLost && r.partial && r.entries < 400_000)
        // Ce que fait l'app ensuite : sans cache ni « Non analysé » pour un volume perdu (le point de montage pointe alors sur un autre disque)
        let used = StorageAnalysis.volumeUsed(img.mount)
        print("  (espace « utilisé » du point de montage vide : \(used.map { Fmt.bytes($0) } ?? "introuvable") : c'est le disque interne, d'où la règle)")
        // Analyse d'un volume déjà absent
        let gone = StorageScan.scan(img.mount)
        check("analyse d'un point de montage disparu : rendue vide (\(gone.entries) éléments)", gone.root.children.isEmpty)
    }
}
