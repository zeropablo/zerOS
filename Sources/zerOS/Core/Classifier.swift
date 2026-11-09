import Foundation
import AppKit

/// Moteur de classification partagé (SPEC.md, Stockage) : chaque dossier ou fichier reçoit une catégorie et la **raison** de ce choix.
/// Ordre : 1) règles de chemins connus (`Classifier.rules`) ; 2) contexte (app propriétaire installée ? ouverte ? zone système ?) ;
/// 3) sinon `Inconnu`. Une catégorie n'autorise jamais rien à elle seule : les protections (`Ignore` : bloqué, lecture seule, projets)
/// priment toujours, et « Inconnu » est en lecture seule.
enum StorageCategory: String, CaseIterable, Codable, Sendable {
    case regenerable, appLeftover, movable, keep, system, unknown

    var label: String {
        switch self {
        case .regenerable: "Régénérable"
        case .appLeftover: "Reste d'app"
        case .movable: "Déplaçable"
        case .keep: "À garder"
        case .system: "Système"
        case .unknown: "Inconnu"
        }
    }

    /// Ce que SPEC.md autorise pour la catégorie (avant les protections).
    var action: String {
        switch self {
        case .regenerable: "Supprimer"
        case .appLeftover: "Corbeille"
        case .movable: "Marche à suivre (jamais de déplacement automatique)"
        case .keep, .system: "Aucune"
        case .unknown: "Lecture seule"
        }
    }
}

struct Classification: Sendable, Equatable {
    var category: StorageCategory
    var reason: String
    /// Identifiant de la règle (autotest), « contexte:… » ou « defaut ».
    var rule: String
    /// Entrée du catalogue « Déplacer vers le disque de données », si la règle en porte une.
    var guide: String? = nil
}

struct ClassRule: Sendable {
    let id: String
    /// Chemin absolu : le dossier et tout ce qu'il contient.
    let path: String
    let category: StorageCategory
    let reason: String
    /// Nom de l'app propriétaire : si elle n'est pas installée, la catégorie devient « Reste d'app ».
    var app: String? = nil
    var guide: String? = nil
}

/// Ce que le moteur sait du Mac : apps installées et ouvertes, bibliothèques de sons à marqueur, dossiers lus dans des préférences.
struct ClassContext: Sendable {
    struct App: Sendable { let name: String; let norm: String; let bundleID: String; let bundleNorm: String; var path = "" }
    var home: String = FS.home.path
    var apps: [App] = []
    /// Noms normalisés des apps ouvertes.
    var running: Set<String> = []
    /// Dossiers de `/Users/Shared` qui contiennent une bibliothèque Native Instruments (`*.nicnt`).
    var nicntFolders: Set<String> = []
    /// Dossiers de cache lus dans les préférences (After Effects, Premiere) : régénérables où qu'ils soient.
    var prefsCaches: [String] = []
    /// Éditeurs vus dans les services d'arrière-plan (« com.google.keystone.agent » → « google »), noms normalisés : un dossier de ce nom
    /// dans Application Support / Caches est un dossier d'éditeur (règle « éditeur absent » des services).
    var servicePublishers: Set<String> = []

    static func norm(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }

    static func app(_ name: String, _ bundleID: String, path: String = "") -> App { App(name: name, norm: norm(name), bundleID: bundleID, bundleNorm: norm(bundleID), path: path) }

    /// Lectures réelles (quelques secondes : Spotlight pour la liste des apps). Jamais bloquant sur un dossier cloud.
    static func live() -> ClassContext {
        var c = ClassContext()
        var seen = Set<String>()
        let r = Shell.run("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle'"], timeout: 60)
        // Seulement les emplacements d'installation : Spotlight trouve aussi des apps dans des archives ou des dossiers de plug-ins.
        let roots = ["/Applications/", "/System/Applications/", "/System/Library/CoreServices/", c.home + "/Applications/"]
        var paths = r.out.components(separatedBy: "\n").filter { p in !p.isEmpty && !p.contains(".app/") && roots.contains { p.hasPrefix($0) } }
        paths += AppCatalog.appURLs().map(\.path)
        for p in Set(paths) {
            let u = URL(fileURLWithPath: p)
            guard let id = FS.bundleInfo(u)?["CFBundleIdentifier"] as? String, seen.insert(p).inserted else { continue }
            c.apps.append(app(FS.displayName(u), id, path: p))
        }
        c.running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName.map(norm) })
        for d in FS.children(URL(fileURLWithPath: "/Users/Shared")) where FS.isDir(d) {
            if FS.children(d, hidden: true).contains(where: { $0.pathExtension == "nicnt" }) { c.nicntFolders.insert(d.lastPathComponent) }
        }
        var caches = CacheScan.prefsCacheFolders().map(\.url)
        if let ae = CacheScan.afterEffectsPrefs() { caches.append(ae.folder) }
        if let mc = CacheScan.premierePrefs().mediaCache { caches.append(mc) }
        c.servicePublishers = Set(BackgroundItems.list().compactMap { i in
            i.label.hasPrefix("com.apple.") ? nil : Services.publisherPrefix(i.label).map { norm(String($0.split(separator: ".")[1])) } })
        c.prefsCaches = caches.map { $0.standardizedFileURL.path }.filter { $0.split(separator: "/").count >= 3 }
        return c
    }

    /// Identifiant sans le préfixe d'un conteneur : « group.net.whatsapp.WhatsApp.shared », « 6N38VWS5BX.ru.keepcoder.Telegram ».
    static func stripped(_ folder: String) -> String {
        var name = folder.lowercased()
        if name.hasPrefix("group.") { name = String(name.dropFirst(6)) }
        if let dot = name.firstIndex(of: "."), name[..<dot].count == 10, name[..<dot].allSatisfy({ $0.isLetter || $0.isNumber }) { name = String(name[name.index(after: dot)...]) }
        return name
    }

    /// Éditeurs des apps installées (deux premiers éléments de l'identifiant : « com.adobe »).
    var vendors: Set<String> { Set(apps.map { $0.bundleID.lowercased().split(separator: ".").prefix(2).joined(separator: ".") }) }

    /// App installée qui correspond à un nom de dossier (identifiant, nom d'app, éditeur), ou nil.
    func owner(of folder: String) -> App? {
        let name = Self.stripped(folder)
        for a in apps {
            let id = a.bundleID.lowercased()
            if name == id || name.hasPrefix(id + ".") || id.hasPrefix(name + ".") || name.hasSuffix("." + id) { return a }
        }
        let n = Self.norm(name)
        guard n.count >= 4 else { return apps.first { $0.norm == n } }
        // Du plus sûr au plus large : nom d'app identique, nom d'app qui commence pareil (ou l'inverse), puis identifiant qui le contient.
        return apps.first { $0.norm == n }
            ?? apps.first { $0.norm.count >= 4 && ($0.norm.hasPrefix(n) || n.hasPrefix($0.norm)) }
            ?? apps.first { $0.bundleNorm.contains(n) }
    }

    /// Éditeurs des apps installées, noms normalisés (« com.google.Chrome » → « google »).
    var vendorNames: Set<String> { Set(apps.compactMap { a in a.bundleID.split(separator: ".").dropFirst().first.map { Self.norm(String($0)) } }) }

    func isRunning(_ a: App) -> Bool { running.contains(a.norm) }
}

enum Classifier {
    // MARK: Règles de chemins connus

    /// `~` = dossier personnel. Plus le chemin est précis, plus la règle l'emporte.
    static func rules(home h: String) -> [ClassRule] {
        let L = h + "/Library", AS = h + "/Library/Application Support"
        func r(_ id: String, _ p: String, _ c: StorageCategory, _ why: String, app: String? = nil, guide: String? = nil) -> ClassRule {
            ClassRule(id: id, path: p, category: c, reason: why, app: app, guide: guide)
        }
        var out: [ClassRule] = [
            // Régénérable
            r("caches", L + "/Caches", .regenerable, "Caches d'apps : recréés automatiquement"),
            r("caches-systeme", "/Library/Caches", .regenerable, "Caches système : recréés automatiquement"),
            r("journaux", L + "/Logs", .regenerable, "Journaux d'apps"),
            r("journaux-systeme", "/Library/Logs", .regenerable, "Journaux système"),
            r("deriveddata", L + "/Developer/Xcode/DerivedData", .regenerable, "Compilations Xcode : recréées à la prochaine compilation"),
            r("caches-appsupport", AS + "/Caches", .regenerable, "Caches rangés dans Application Support"),
            r("corbeille", h + "/.Trash", .regenerable, "Corbeille : déjà jetée, se vide"),
            r("cache-dot", h + "/.cache", .regenerable, "Cache d'outils en ligne de commande"),
            r("cache-npm", h + "/.npm/_cacache", .regenerable, "Cache npm"),
            r("adobe-media-cache", AS + "/Adobe/Common/Media Cache Files", .regenerable, "Cache média Adobe (Premiere, After Effects) : recréé à l'ouverture des projets", guide: "adobe-cache"),
            r("adobe-media-cache-db", AS + "/Adobe/Common/Media Cache", .regenerable, "Base du cache média Adobe", guide: "adobe-cache"),
            r("adobe-peak", AS + "/Adobe/Common/Peak Files", .regenerable, "Fichiers de pics audio Adobe", guide: "adobe-cache"),
            // Déplaçable (marche à suivre dans le catalogue, jamais de déplacement automatique)
            r("whisky-conteneur", L + "/Containers/com.franke.Whisky", .movable, "Bouteilles Whisky (Windows sous Wine) : l'emplacement se change dans Whisky", app: "Whisky", guide: "whisky"),
            r("whisky-support", AS + "/com.franke.Whisky", .movable, "Données Whisky : l'emplacement se change dans Whisky", app: "Whisky", guide: "whisky"),
            r("prism", AS + "/PrismLauncher", .movable, "Instances Minecraft de Prism Launcher : dossier réglable dans l'app", app: "Prism Launcher", guide: "prism"),
            r("ni-support", "/Library/Application Support/Native Instruments", .movable, "Contenu Native Instruments : emplacement réglable dans Native Access", app: "Native Access", guide: "native-access"),
            r("ni-partage", "/Users/Shared/Native Instruments", .movable, "Contenu Native Instruments : emplacement réglable dans Native Access", app: "Native Access", guide: "native-access"),
            r("ni-ressources", "/Users/Shared/NI Resources", .movable, "Ressources Native Instruments : emplacement réglable dans Native Access", app: "Native Access", guide: "native-access"),
            r("spitfire-partage", "/Users/Shared/Spitfire Audio", .movable, "Bibliothèques Spitfire : emplacement réglable dans l'app Spitfire Audio", app: "Spitfire Audio", guide: "spitfire"),
            r("spitfire-home", h + "/Spitfire", .movable, "Bibliothèques Spitfire : emplacement réglable dans l'app Spitfire Audio", app: "Spitfire Audio", guide: "spitfire"),
            r("logic-sons", "/Library/Application Support/Logic", .movable, "Bibliothèque de sons de Logic Pro : déplaçable depuis Logic", app: "Logic Pro", guide: "logic"),
            r("apple-loops", "/Library/Audio/Apple Loops", .movable, "Apple Loops (Logic Pro, GarageBand) : bibliothèque de sons déplaçable depuis Logic", app: "Logic Pro", guide: "logic"),
            r("ableton-support", AS + "/Ableton", .movable, "Données Ableton Live : packs et User Library réglables dans Live", app: "Ableton Live", guide: "ableton"),
            r("ableton-musique", h + "/Music/Ableton", .movable, "Packs et User Library d'Ableton Live : emplacement réglable dans Live", app: "Ableton Live", guide: "ableton"),
            r("steam", AS + "/Steam", .movable, "Jeux Steam : bibliothèques sur un autre disque via Steam", app: "Steam", guide: "steam"),
            // À garder
            r("documents", h + "/Documents", .keep, "Dossier personnel : vos documents"),
            r("bureau", h + "/Desktop", .keep, "Dossier personnel : le Bureau"),
            r("telechargements", h + "/Downloads", .keep, "Dossier personnel : Téléchargements (voir Mon désordre)"),
            r("images", h + "/Pictures", .keep, "Dossier personnel : vos images"),
            r("musique", h + "/Music", .keep, "Dossier personnel : votre musique et vos projets"),
            r("films", h + "/Movies", .keep, "Dossier personnel : vos films et projets vidéo"),
            r("apps", "/Applications", .keep, "Apps installées"),
            r("apps-perso", h + "/Applications", .keep, "Apps installées"),
            r("messages", L + "/Messages", .keep, "Pièces jointes et historique de Messages"),
            r("mail", L + "/Mail", .keep, "Courrier de l'app Mail"),
            r("photos-lib", L + "/Photos", .keep, "Données de l'app Photos"),
            r("icloud", L + "/Mobile Documents", .keep, "iCloud Drive (voir Cloud)"),
            r("safari", L + "/Safari", .keep, "Données de Safari"),
            r("iphone", AS + "/MobileSync", .keep, "Sauvegardes d'iPhone / iPad"),
            r("plugins-audio", "/Library/Audio/Plug-Ins", .keep, "Plug-ins audio installés (VST, AU, CLAP…)"),
            r("presets-audio", "/Library/Audio/Presets", .keep, "Presets des plug-ins audio"),
            r("audio-autre", "/Library/Audio", .keep, "Réglages et contenus audio installés"),
            r("outils-dev", "/Library/Developer", .keep, "Outils développeur installés (Xcode, Command Line Tools)"),
            r("frameworks", "/Library/Frameworks", .keep, "Bibliothèques installées par des apps"),
            r("helpers", "/Library/PrivilegedHelperTools", .keep, "Outils installés par des apps"),
            r("homebrew", "/opt/homebrew", .keep, "Homebrew et ses paquets"),
            // Système
            r("systeme", "/System", .system, "Volume système scellé de macOS"),
            r("assetsv2", "/System/Library/AssetsV2", .system, "Ressources téléchargées par macOS (langues, voix, modèles) : gérées par macOS"),
            r("usr", "/usr", .system, "Outils de macOS"),
            r("bin", "/bin", .system, "Outils de macOS"),
            r("sbin", "/sbin", .system, "Outils de macOS"),
            r("var-db", "/private/var/db", .system, "Bases de données de macOS (Spotlight, mises à jour, services)"),
            r("var-folders", "/private/var/folders", .system, "Fichiers temporaires et caches gérés par macOS (se vident au redémarrage)"),
            r("var-vm", "/private/var/vm", .system, "Fichiers d'échange de la mémoire (swap)"),
            r("var", "/private/var", .system, "Données variables de macOS"),
            r("etc", "/private/etc", .system, "Configuration de macOS"),
            r("cores", "/cores", .system, "Dossier de macOS"),
            r("lib-apple", "/Library/Apple", .system, "Composants ajoutés par macOS"),
            r("lib-fonds", "/Library/Desktop Pictures", .system, "Fonds d'écran de macOS"),
            r("lib-trial", "/Library/Trial", .system, "Expérimentations de macOS"),
            r("lib-prefs", "/Library/Preferences", .system, "Réglages système"),
            r("lib-printers", "/Library/Printers", .system, "Imprimantes"),
            r("lib-doc", "/Library/Documentation", .system, "Documentation de macOS"),
            r("lib-bluetooth", "/Library/Bluetooth", .system, "Bluetooth"),
            r("lib-capture", "/Library/Image Capture", .system, "Capture d'image"),
        ]
        // Services macOS dans la Bibliothèque personnelle
        for (n, why) in [("Metadata", "Index Spotlight et métadonnées gérés par macOS"), ("Biome", "Données de suggestions et d'apprentissage de macOS"),
                         ("DuetExpertCenter", "Données de suggestions de macOS"), ("IntelligencePlatform", "Données d'Apple Intelligence"),
                         ("Daemon Containers", "Conteneurs de services macOS"), ("Trial", "Expérimentations de macOS"),
                         ("AppleMediaServices", "Services multimédia d'Apple"), ("IdentityServices", "Services d'identité Apple")] {
            out.append(r("svc-" + n.lowercased().replacingOccurrences(of: " ", with: "-"), L + "/" + n, .system, why))
        }
        // Données de plug-ins et d'extensions (éditeurs) dans /Library/Application Support
        for n in ["MeldaProduction", "AEJuice", "iZotope", "Slate Digital", "Kilohearts", "Aberrant DSP", "Acon Digital"] {
            out.append(r("editeur-" + n.lowercased().replacingOccurrences(of: " ", with: "-"), "/Library/Application Support/" + n, .keep, "Données du plug-in « \(n) » installé"))
        }
        out.append(r("cycling74", AS + "/Cycling '74", .keep, "Données de Max / Cycling '74 installé"))
        out.append(r("xfer", "/Library/Audio/Presets/Xfer Records", .keep, "Presets Xfer Records (Serum…)"))
        return out
    }

    /// Dossiers dont chaque enfant appartient à une app : l'app propriétaire décide (installée → À garder).
    static func ownerDirs(home h: String) -> Set<String> {
        let L = h + "/Library"
        return Set(["Application Support", "Containers", "Group Containers", "Application Scripts", "Saved Application State", "Preferences", "HTTPStorages", "WebKit", "Cookies"].map { L + "/" + $0 }
                   + ["/Library/Application Support", "/Users/Shared"])
    }

    /// Noms de caches du moteur web des apps Electron / Chromium rangés dans Application Support.
    static let webCacheNames: Set<String> = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "ShaderCache", "GrShaderCache", "Service Worker", "blob_storage"]

    /// Cherche d'abord la règle la plus précise sur le chemin et ses parents ; sans règle, le contexte ; sinon Inconnu.
    static func classify(_ path: String, context c: ClassContext, rules byPath: [String: ClassRule]? = nil) -> Classification {
        let table = byPath ?? Dictionary(rules(home: c.home).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let owners = ownerDirs(home: c.home)
        if path == "/" { return Classification(category: .system, reason: "Racine du disque", rule: "racine") }
        var cur = path
        while cur.count > 1 {
            let parent = (cur as NSString).deletingLastPathComponent
            let name = (cur as NSString).lastPathComponent
            // Dossiers de cache lus dans les préférences (Adobe) : régénérables où qu'ils soient.
            if c.prefsCaches.contains(cur) {
                return Classification(category: .regenerable, reason: "Cache Adobe dont l'emplacement est lu dans les préférences (After Effects / Premiere)", rule: "adobe-prefs", guide: "adobe-cache")
            }
            // ~/Library/Caches : un dossier d'éditeur absent est un reste d'app avant d'être un simple cache.
            if parent == c.home + "/Library/Caches", let p = publisherFolder(name, c), p.category == .appLeftover { return p }
            if let rule = table[cur] { return apply(rule, c) }
            if webCacheNames.contains(name), parent.hasPrefix(c.home + "/Library/Application Support/") {
                return Classification(category: .regenerable, reason: "Cache du moteur web de l'app (« \(name) ») : recréé automatiquement", rule: "cache-web")
            }
            if name == "CACHES", parent.hasPrefix("/Volumes/"), parent.split(separator: "/").count == 2 {
                return Classification(category: .regenerable, reason: "Dossier CACHES d'un disque (caches Adobe) : recréé automatiquement", rule: "volume-caches", guide: "adobe-cache")
            }
            if parent.hasPrefix("/Volumes/"), parent.split(separator: "/").count == 2, [".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems"].contains(name) {
                return Classification(category: .system, reason: "Index et journaux du disque, gérés par macOS", rule: "volume-systeme")
            }
            if parent.hasPrefix("/Volumes/"), parent.split(separator: "/").count == 2, [".Trashes", ".Trash"].contains(name) {
                return Classification(category: .regenerable, reason: "Corbeille du disque : déjà jetée, se vide", rule: "volume-corbeille")
            }
            if cur.hasSuffix(".photoslibrary"), parent == c.home + "/Pictures" {
                let app = c.owner(of: "Photos")
                return Classification(category: .movable, reason: "Photothèque de Photos : se déplace en la copiant puis en la choisissant dans Photos" + (app.map { c.isRunning($0) ? " (Photos est ouverte)" : "" } ?? ""),
                                      rule: "photothèque", guide: "photos")
            }
            if owners.contains(parent) { return owned(name: name, in: parent, c) }
            cur = parent
        }
        return Classification(category: .unknown, reason: "Aucune règle ne couvre ce dossier", rule: "defaut")
    }

    private static func apply(_ rule: ClassRule, _ c: ClassContext) -> Classification {
        guard let appName = rule.app else {
            return Classification(category: rule.category, reason: rule.reason, rule: rule.id, guide: rule.guide)
        }
        guard let app = c.owner(of: appName) else {
            return Classification(category: .appLeftover, reason: "App « \(appName) » introuvable sur ce Mac : ces données lui appartenaient (\(rule.reason))", rule: rule.id, guide: rule.guide)
        }
        let open = c.isRunning(app) ? " (app ouverte)" : ""
        return Classification(category: rule.category, reason: rule.reason + open, rule: rule.id, guide: rule.guide)
    }

    /// Dossier d'éditeur (« Google ») : même règle que les services. Éditeur vu dans les services et aucune app installée → reste d'app.
    private static func publisherFolder(_ name: String, _ c: ClassContext) -> Classification? {
        let n = ClassContext.norm(name)
        guard c.servicePublishers.contains(n) else { return nil }
        if c.vendorNames.contains(n) {
            return Classification(category: .keep, reason: "Dossier de l'éditeur « \(name) », dont une app est installée", rule: "contexte:editeur-installe")
        }
        return Classification(category: .appLeftover, reason: "Dossier de l'éditeur « \(name) » : aucune app installée de cet éditeur (ses services d'arrière-plan sont encore là)", rule: "contexte:editeur-absent")
    }

    /// Enfant d'un dossier d'apps : le contexte (app installée ?) décide.
    private static func owned(name: String, in parent: String, _ c: ClassContext) -> Classification {
        let lower = name.lowercased()
        if parent == "/Users/Shared" {
            if c.nicntFolders.contains(name) {
                let app = c.owner(of: "Native Access")
                let why = "Bibliothèque Native Instruments (marqueur .nicnt) : emplacement réglable dans Native Access"
                guard app != nil else { return Classification(category: .appLeftover, reason: "Native Access introuvable : " + why, rule: "contexte:ni-bibliotheque", guide: "native-access") }
                return Classification(category: .movable, reason: why, rule: "contexte:ni-bibliotheque", guide: "native-access")
            }
            if lower.contains("spitfire") { return apply(ClassRule(id: "contexte:spitfire", path: "", category: .movable, reason: "Bibliothèque Spitfire : emplacement réglable dans l'app Spitfire Audio", app: "Spitfire Audio", guide: "spitfire"), c) }
        }
        if lower.hasPrefix("com.apple.") || lower.hasPrefix("group.com.apple.") || lower == "apple" {
            return Classification(category: .keep, reason: "Données d'une app ou d'un service Apple", rule: "contexte:apple")
        }
        if let app = c.owner(of: name) {
            return Classification(category: .keep, reason: "Données de « \(app.name) » (app installée\(c.isRunning(app) ? ", ouverte" : ""))", rule: "contexte:app-installee")
        }
        if let p = publisherFolder(name, c) { return p }
        // Un identifiant d'app (a.b.c) sans app correspondante : reste d'app, sauf si l'éditeur a une autre app installée (composant partagé).
        if name.split(separator: ".").count >= 3, !name.hasPrefix("com.zeropablo.") {
            let vendor = ClassContext.stripped(name).split(separator: ".").prefix(2).joined(separator: ".")
            if c.vendors.contains(vendor) {
                return Classification(category: .keep, reason: "Composant de l'éditeur « \(vendor) », dont une app est installée : gardé par prudence", rule: "contexte:editeur-installe")
            }
            return Classification(category: .appLeftover, reason: "Aucune app installée ne correspond à « \(name) » : reste d'une app supprimée", rule: "contexte:orphelin")
        }
        return Classification(category: .unknown, reason: "Aucune règle, et aucune app installée ne porte ce nom", rule: "defaut")
    }
}
