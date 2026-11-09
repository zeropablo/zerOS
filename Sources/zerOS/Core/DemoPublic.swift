import Foundation

/// Captures publiques : `--demo-public` remplace les données réelles de ce Mac (apps, dossiers, caches) par des données génériques.
/// Jamais actif en fonctionnement normal ; ne lit ni n'écrit rien de réel.
enum DemoPublic {
    static let on = CommandLine.arguments.contains("--demo-public")
    static let home = "/Users/demo"
    static let gb: Int64 = 1_000_000_000
    static let mb: Int64 = 1_000_000

    // MARK: Apps (Apps > Désinstallation)

    static var apps: [AppInfo] {
        func app(_ name: String, _ id: String, _ v: String, _ mbSize: Int64, _ days: Int, store: Bool = false) -> AppInfo {
            AppInfo(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, bundleID: id, version: v, build: v, size: mbSize * mb,
                    lastUsed: Date().addingTimeInterval(-Double(days) * 86400), isAppStore: store, isApple: false, feedURL: nil)
        }
        return [
            app("Studio Vidéo", "com.exemple.studiovideo", "14.2", 6400, 2),
            app("Éditeur Photo", "com.exemple.editeurphoto", "9.1", 3100, 5),
            app("Atelier Son", "com.exemple.ateliersong", "5.8", 2200, 9),
            app("Jeu de Plateau", "com.exemple.jeuplateau", "2.0", 1800, 240),
            app("Carnet de Notes", "com.exemple.carnet", "3.4", 420, 1, store: true),
            app("Lecteur Média", "com.exemple.lecteur", "7.6", 310, 14),
            app("Convertisseur", "com.exemple.convertisseur", "1.9", 180, 320),
            app("Gestionnaire de Mots de Passe", "com.exemple.mdp", "8.2", 150, 3),
            app("Capture Rapide", "com.exemple.capture", "4.1", 95, 40, store: true),
            app("Éditeur de Texte", "com.exemple.texte", "6.0", 88, 6),
        ]
    }

    // MARK: Déplacer

    static func relocate() -> [RelocateItem] {
        func installed(_ name: String) -> [ClassContext.App] { [ClassContext.app(name, "com.exemple." + ClassContext.norm(name))] }
        return Relocate.catalog.compactMap { e in
            let sizes: [String: (Int64, String)] = [
                "steam": (46 * gb, "Steam"), "logic": (38 * gb, "Logic Pro"), "ableton": (14 * gb, "Ableton Live"), "photos": (31 * gb, "Photos"),
            ]
            guard let (size, app) = sizes[e.id] else { return nil }
            return RelocateItem(entry: e, folders: [("\(home)/Library/Application Support/\(e.short)", size)], installed: installed(app))
        }
    }

    // MARK: Stockage > Arborescence

    static func tree() -> StorageScan.DTO {
        func d(_ n: String, _ g: Double, _ c: [StorageScan.DTO] = []) -> StorageScan.DTO {
            let x = SNode(name: n, size: Int64(g * Double(gb)), isDir: true)
            var dto = StorageScan.DTO(x); dto.c = c; return dto
        }
        func f(_ n: String, _ g: Double) -> StorageScan.DTO { StorageScan.DTO(SNode(name: n, size: Int64(g * Double(gb)), isDir: false)) }
        let user = d("demo", 214, [
            d("Movies", 62, [d("Montages", 41), d("Rushes", 21)]),
            d("Documents", 41, [d("Travail", 24), d("Archives", 17)]),
            d("Library", 39, [d("Caches", 7), d("Application Support", 24), d("Containers", 6), d("Logs", 0.6)]),
            d("Pictures", 26), d("Music", 18), d("Downloads", 12, [f("installateur.dmg", 3.2), f("film-test.mov", 2.4)]), d("Desktop", 3),
            d("Applications", 13),
        ])
        let root = d("/", 337, [
            d("Applications", 42, [d("Studio Vidéo.app", 8), d("Éditeur Photo.app", 4), d("Atelier Son.app", 3), d("Jeu de Plateau.app", 2)]),
            d("System", 24), d("Library", 14, [d("Application Support", 7), d("Frameworks", 4)]),
            d("Users", 219, [user, d("Shared", 5)]),
            d("private", 20, [d("var", 14, [d("vm", 8)])]),
            d("opt", 1.0),
        ])
        return root
    }

    static func cached() -> StorageScan.Cached {
        StorageScan.Cached(root: tree(), date: Date().addingTimeInterval(-3600), partial: false, entries: 1_842_310, seconds: 19.4, version: StorageScan.rulesVersion)
    }

    // MARK: Stockage > Nettoyage

    static func cleanup() -> [CleanGroup] {
        func it(_ t: String, _ sub: String, _ mbSize: Int64, _ sym: String, mode: RemovalMode = .emptyDir) -> CleanItem {
            CleanItem(url: URL(fileURLWithPath: "\(home)/Library/Caches/\(t)"), title: t, subtitle: sub, size: mbSize * mb, mode: mode, preselected: true, symbol: sym)
        }
        let caches = CleanGroup(id: "user-caches", title: "Caches des apps", subtitle: "Recréés tout seuls par les apps", symbol: "archivebox", items: [
            it("Studio Vidéo", "com.exemple.studiovideo", 3400, "film"), it("Éditeur Photo", "com.exemple.editeurphoto", 1700, "photo"),
            it("Atelier Son", "com.exemple.ateliersong", 920, "waveform"), it("Navigateur", "com.exemple.navigateur", 740, "globe"),
            it("Lecteur Média", "com.exemple.lecteur", 260, "play.rectangle"), it("Éditeur de Texte", "com.exemple.texte", 85, "doc.text"),
        ], regenerable: true)
        let logs = CleanGroup(id: "user-logs", title: "Journaux des apps", subtitle: "Fichiers de suivi anciens", symbol: "doc.plaintext", items: [
            it("Journaux de Studio Vidéo", "Journaux", 210, "doc.plaintext"), it("Journaux d'Atelier Son", "Journaux", 64, "doc.plaintext"),
        ], regenerable: true)
        let sys = CleanGroup(id: "system-caches", title: "Caches du système", subtitle: "Recréés par macOS", symbol: "gearshape", items: [
            it("Cache des polices", "Système", 380, "textformat"), it("Cache des miniatures", "Système", 520, "square.grid.2x2"),
        ], regenerable: true)
        return [caches, logs, sys].map { $0.protected() }
    }
}
