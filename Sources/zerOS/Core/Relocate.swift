import Foundation
import AppKit
import Darwin

/// Catalogue « Déplacer vers le disque de données » (SPEC.md) : des apps dont les données se déplacent par leur propre réglage.
/// zerOS ne déplace rien : il mesure la place prise sur le disque interne, donne la marche à suivre et ouvre l'app quand c'est possible.
/// Les dossiers mesurés sont ceux des règles du moteur de classification (`ClassRule.guide`), donc une seule source de vérité.
struct RelocateEntry: Identifiable, Sendable {
    let id: String
    let name: String
    /// Nom court pour les actions d'Aujourd'hui (« Déplacer Whisky : 9 Go »).
    let short: String
    /// Apps à ouvrir (noms), la première qui est installée sert au contrôle « installée ».
    let apps: [String]
    let steps: [String]
    var note: String? = nil
    /// Tant que la procédure n'a pas été confirmée sur la version installée, elle est annoncée comme telle dans la page.
    var unverified: String? = "Procédure non vérifiée : écrite de mémoire, les libellés des menus peuvent différer selon la version de l'app."
}

struct RelocateItem: Identifiable, Sendable {
    var id: String { entry.id }
    let entry: RelocateEntry
    /// Dossiers existants sur le disque interne et leur taille.
    var folders: [(path: String, size: Int64)]
    /// App installée par nom d'app du catalogue.
    var installed: [ClassContext.App]
    var size: Int64 { folders.reduce(0) { $0 + $1.size } }
}

enum Relocate {
    static let catalog: [RelocateEntry] = [
        RelocateEntry(id: "whisky", name: "Whisky (bouteilles)", short: "Whisky", apps: ["Whisky"], steps: [
            "Branchez le disque de données et quittez les programmes lancés dans Whisky.",
            "Dans Whisky, clic droit sur une bouteille, puis « Move Bottle… » (« Déplacer la bouteille… ») et choisissez un dossier sur le disque de données. Le libellé exact dépend de la version de Whisky.",
            "Lancez un programme de la bouteille pour vérifier qu'elle fonctionne, avant de supprimer quoi que ce soit.",
            "Les bouteilles restantes se trouvent dans ~/Library/Containers/com.franke.Whisky/Bottles."],
            unverified: "Procédure non vérifiée en entier : une action « Move Bottle » existe bien dans la version installée de Whisky (relevée dans l'app), mais son emplacement dans les menus et son libellé exact ne sont pas confirmés."),
        RelocateEntry(id: "prism", name: "Prism Launcher (instances Minecraft)", short: "Prism Launcher", apps: ["Prism Launcher"], steps: [
            "Quittez Prism Launcher.",
            "Dans le Finder, copiez le dossier « instances » de ~/Library/Application Support/PrismLauncher vers le disque de données.",
            "Rouvrez Prism Launcher : Réglages (⌘,) ▸ Dossiers ▸ « Dossier des instances », choisissez la copie.",
            "Vérifiez qu'une instance se lance, puis seulement après, supprimez l'ancien dossier."]),
        RelocateEntry(id: "native-access", name: "Native Instruments (bibliothèques de Native Access)", short: "Native Instruments", apps: ["Native Access"], steps: [
            "Branchez le disque de données.",
            "Dans Native Access : Préférences ▸ « Content Location » (emplacement du contenu) ▸ « Change ». Native Access déplace lui-même les bibliothèques et garde ses licences.",
            "Les bibliothèques sont dans /Users/Shared (dossiers « … Library ») et /Library/Application Support/Native Instruments.",
            "Rouvrez Kontakt : les bibliothèques doivent rester reconnues."]),
        RelocateEntry(id: "spitfire", name: "Spitfire Audio (bibliothèques LABS)", short: "Spitfire", apps: ["Spitfire Audio"], steps: [
            "Branchez le disque de données et quittez votre logiciel de musique.",
            "Dans l'app Spitfire Audio : Réglages (roue dentée) ▸ emplacement des bibliothèques (« Library location »), puis choisissez un dossier sur le disque de données. L'app propose de déplacer les bibliothèques déjà installées.",
            "Rouvrez une bibliothèque LABS dans votre logiciel pour vérifier."]),
        RelocateEntry(id: "logic", name: "Logic Pro (bibliothèque de sons, Apple Loops)", short: "Logic Pro", apps: ["Logic Pro", "Logic Pro Creator Studio"], steps: [
            "Branchez le disque de données.",
            "Dans Logic Pro : menu « Logic Pro » ▸ « Bibliothèque de sons » ▸ « Déplacer la bibliothèque de sons… » (« Relocate Sound Library… »), puis choisissez un dossier sur le disque de données. Logic copie et gère le reste.",
            "Le disque devra être branché pour utiliser ces sons."]),
        RelocateEntry(id: "ableton", name: "Ableton Live (packs, User Library)", short: "Ableton Live", apps: ["Ableton Live 12 Suite", "Ableton Live"], steps: [
            "Quittez Live et branchez le disque de données.",
            "Dans le Finder, copiez les dossiers à déplacer (packs, User Library) vers le disque de données.",
            "Rouvrez Live : Réglages (⌘,) ▸ « Bibliothèque » ▸ choisissez le nouvel emplacement des packs et de la User Library.",
            "Vérifiez qu'un projet s'ouvre sans sample manquant, puis supprimez les anciens dossiers."]),
        RelocateEntry(id: "steam", name: "Steam (bibliothèque de jeux)", short: "Steam", apps: ["Steam"], steps: [
            "Dans Steam : Réglages ▸ Stockage ▸ « + » pour ajouter un dossier de bibliothèque sur le disque de données.",
            "Pour chaque jeu : clic droit ▸ Propriétés ▸ Fichiers installés ▸ « Déplacer le dossier d'installation », puis choisissez la nouvelle bibliothèque."]),
        RelocateEntry(id: "photos", name: "Photos (photothèque)", short: "Photos", apps: ["Photos"], steps: [
            "Quittez Photos.",
            "Dans le Finder, copiez la photothèque (~/Pictures, fichier .photoslibrary) vers le disque de données.",
            "Ouvrez Photos en maintenant la touche ⌥ (Option), choisissez « Autre photothèque… » et sélectionnez la copie.",
            "Photos ▸ Réglages ▸ Général ▸ « Utiliser comme photothèque système » si c'est votre photothèque principale. Vérifiez, puis supprimez l'ancienne."],
            note: "Les photothèques sont en lecture seule dans zerOS : il ne les touche jamais."),
        RelocateEntry(id: "adobe-cache", name: "Caches Adobe (After Effects, Premiere Pro)", short: "Caches Adobe", apps: ["Adobe After Effects 2026", "Adobe After Effects", "Adobe Premiere Pro 2026", "Adobe Premiere Pro"], steps: [
            "After Effects : Réglages ▸ Média et cache disque ▸ Cache disque ▸ « Choisir le dossier… ».",
            "Premiere Pro : Réglages ▸ Cache du média ▸ « Parcourir… » pour le cache et les fichiers de pics.",
            "Choisissez un dossier sur le disque de données (par exemple « CACHES »). L'ancien contenu se vide depuis Stockage ▸ Nettoyage."],
            note: "Un cache déjà placé sur un autre disque n'apparaît pas ici : seul ce qui reste sur le disque interne est compté."),
    ]

    /// Dossiers du disque interne qui appartiennent à une entrée : ceux des règles du moteur, plus les bibliothèques à marqueur .nicnt.
    static func paths(for id: String, context: ClassContext) -> [String] {
        var out = Classifier.rules(home: context.home).filter { $0.guide == id }.map(\.path)
        if id == "native-access" { out += context.nicntFolders.map { "/Users/Shared/" + $0 } }
        if id == "adobe-cache" { out += context.prefsCaches.filter { $0.hasPrefix("/Volumes/") == false } }
        if id == "photos" { out += FS.children(URL(fileURLWithPath: context.home + "/Pictures")).filter { $0.pathExtension == "photoslibrary" }.map(\.path) }
        return Array(Set(out)).sorted()
    }

    /// Tailles sur le disque interne (lecture seule, hors du fil principal). Un dossier sur un autre disque n'est jamais compté.
    static func measure(context: ClassContext) -> [RelocateItem] {
        if DemoPublic.on { return DemoPublic.relocate() }
        return catalog.map { e in
            let folders = paths(for: e.id, context: context).filter { FS.exists(URL(fileURLWithPath: $0)) && !$0.hasPrefix("/Volumes/") }
                .map { ($0, StorageScan.size(of: $0)) }
            let apps = e.apps.compactMap { context.owner(of: $0) }
            var seen = Set<String>()
            return RelocateItem(entry: e, folders: folders, installed: apps.filter { seen.insert($0.path).inserted })
        }
    }
}

/// Résultat partagé (Stockage ▸ Déplacer et actions d'Aujourd'hui) : mesuré une fois, rafraîchi à la demande.
@MainActor
final class RelocateModel: ObservableObject {
    static let shared = RelocateModel()
    @Published var items: [RelocateItem] = []
    @Published var loading = false
    @Published var measuredAt: Date?

    func refresh(force: Bool = false) {
        guard !loading, force || measuredAt.map({ Date().timeIntervalSince($0) > 3600 }) ?? true else { return }
        loading = true
        Task.detached(priority: .utility) {
            let ctx = ClassContext.live()
            let items = Relocate.measure(context: ctx)
            await MainActor.run { let m = RelocateModel.shared; m.items = items; m.loading = false; m.measuredAt = Date() }
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    /// Ce que propose Aujourd'hui : apps installées avec des données sur le disque interne.
    var movable: [(name: String, bytes: Int64)] {
        items.filter { !$0.installed.isEmpty && $0.size > 0 && $0.entry.id != "photos" && $0.entry.id != "adobe-cache" }.map { ($0.entry.short, $0.size) }
    }
}
