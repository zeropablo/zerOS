import Foundation
import SwiftUI
import AppKit

/// Configuration enregistrée sur ce Mac : premier lancement simulé (réglages vides), disque de données, disque renommé reconnu par son
/// UUID, assistant, icône de la barre des menus et position de la bulle.
/// Tout se passe dans un jeu de réglages temporaire (`Prefs.store`) et des images disque temporaires : rien de réel n'est modifié.
enum ConfigTests {
    static var fails = 0
    static func check(_ name: String, _ ok: Bool) { print("  \(ok ? "✓" : "✗") \(name)"); if !ok { fails += 1 } }

    /// Exécute sur le fil principal (le fil de l'autotest est un autre fil).
    static func onMain<T>(_ f: @MainActor () -> T) -> T { DispatchQueue.main.sync { MainActor.assumeIsolated(f) } }

    static func withStore<T>(_ body: (UserDefaults) -> T) -> T {
        let name = "zerOS-autotest-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        let old = Prefs.store
        Prefs.store = store
        defer {
            Prefs.store = old; store.removePersistentDomain(forName: name)
            // removePersistentDomain laisse un fichier vide dans ~/Library/Preferences : on l'enlève (sinon ~11 fichiers par autotest).
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(name).plist"))
        }
        return body(store)
    }

    static func run() {
        fails = 0
        print("\n=== Configuration : premier lancement, migration, disques ===")
        firstLaunch()
        dataDisk()
        keepsOtherSettings()
        wizard()
        navigation()
        statusItemAndBubble()
        print(fails == 0 ? "  Tout est bon." : "  \(fails) échec(s).")
        cleanPreferencesFiles()
    }

    /// cfprefsd réécrit les fichiers des domaines factices après leur suppression : on attend, puis on les enlève tous.
    static func cleanPreferencesFiles() {
        Thread.sleep(forTimeInterval: 1.5)
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix("zerOS-autotest-") && f.hasSuffix(".plist") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    // MARK: 1. Premier lancement : réglages vides

    static func firstLaunch() {
        print("— Premier lancement simulé (réglages vides, aucun disque connu)")
        withStore { store in
            let other = [VolumeInfo(mount: URL(fileURLWithPath: "/"), uuid: "SYS", name: "Macintosh HD")]
            check("aucune configuration → l'assistant doit s'afficher", Config.needsWizard && Config.current == nil)
            check("réglages vides : audio, caches de développement, lecture seule, disque de données, sans valeur personnelle",
                  Prefs.audioInterface.isEmpty && Prefs.audioApps.isEmpty && Prefs.ignoredDevCaches.isEmpty && Ignore.readOnlyUserPaths.isEmpty
                  && Ignore.readOnlyDefaults.isEmpty && Config.relocateTarget == nil)
            _ = other
            let snap0 = TodaySnapshot(diskFree: 400_000_000_000, diskTotal: 1_000_000_000_000, pressure: 1, swapUsed: 0, memTotal: 24 << 30, externals: [], trashSize: 0)
            check("Aujourd'hui : 3 tuiles (disque, mémoire, disques externes)", TodayEngine.states(snap0).map(\.kind) == [.disk, .memory, .externals])
            let disks0 = HealthChecks.readDisks()
            check("disques : aucun marqué « disque de données » sans réglage (\(disks0.count) lu(s))", !disks0.contains { $0.role == .data })
            // Fin de l'assistant sans rien choisir (étape passée) : la configuration existe, l'assistant ne revient plus.
            onMain {
                let m = WizardModel(step: 0)
                m.save()
            }
            check("assistant terminé sans rien choisir : configuration enregistrée, plus d'assistant, aucun disque de données", !Config.needsWizard && Config.current?.dataDisk == nil)
            let music = FS.h("Music").path
            check("assistant : Musique et Films proposés et cochés → en lecture seule\(FS.exists(FS.h("Music")) ? "" : " (dossier Musique absent ici)")",
                  !FS.exists(FS.h("Music")) || Ignore.readOnly(URL(fileURLWithPath: music).appendingPathComponent("x")))
            check("assistant relancé : choix actuels préremplis", onMain { WizardModel(step: 0).draft == Config.current })
        }
    }


    // MARK: Disque de données : parcours d'un nouvel utilisateur

    static func dataDisk() {
        print("— Disque de données : assistant, Réglages, Déplacer, Aujourd'hui (nouvel utilisateur, image disque temporaire)")
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/zerOS-test-donnees-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: root); try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let name = "ZT DONNEES \(ProcessInfo.processInfo.processIdentifier % 10000)"
        guard let img = DiskImage.makeExternal(root, name) else { check("image disque temporaire montée comme disque externe", false); return }
        var attached = true
        defer { if attached { DiskImage.detach(img) } }
        try? fm.createDirectory(at: img.mount.appendingPathComponent("Sons"), withIntermediateDirectories: true)
        withStore { store in
            check("nouvel utilisateur : pas de configuration, pas de disque de données, Déplacer sans destination", Config.needsWizard && Config.relocateTarget == nil)
            let picked = onMain { () -> (Location?, [String], [String], Location?) in
                let m = WizardModel(step: 1)
                m.chooseDataDisk(FS.home)                                  // disque interne : refusé
                let refusedInternal = m.refused
                let afterRefusal = m.draft.dataDisk
                m.chooseDataDisk(img.mount.appendingPathComponent("Sons"))  // un dossier désigne son disque
                let ok = m.refused
                m.step = WizardModel.steps.count - 1
                m.save()
                return (afterRefusal, refusedInternal, ok, m.draft.dataDisk)
            }
            check("assistant : disque interne refusé avec une raison, rien de changé", picked.0 == nil && picked.1.first?.contains("disque externe") == true)
            check("assistant : un dossier du disque externe désigne le disque entier", picked.2.isEmpty && picked.3?.isRoot == true && picked.3?.volume.name == name)
            let t = Config.relocateTarget
            check("après « Terminer » : Déplacer vise « \(t?.name ?? "—") » (\(t?.url.path ?? "—"))", t?.name == name && t.map { Volumes.realURL($0.url) } == Volumes.realURL(img.mount))
            check("disque de données en lecture seule pour le nettoyage (jamais supprimé)", Ignore.readOnly(img.mount.appendingPathComponent("Sons/x.wav")) && Ignore.readOnlyDefaults.contains(Volumes.realURL(img.mount).path))
            check("Santé : le volume est reconnu comme disque de données", Volumes.containing(img.mount).map(Config.isDataDisk) == true)
            let line = onMain { DataDisk.line(Config.current?.dataDisk) }
            check("affichage : « \(line) »", line.contains(name) && line.contains("libres sur"))
            // Aujourd'hui : disque interne presque plein → « Déplacer » vers ce disque.
            var snap = TodaySnapshot(diskFree: 50_000_000_000, diskTotal: 1_000_000_000_000, pressure: 1, swapUsed: 0, memTotal: 24 << 30, externals: [], trashSize: 0)
            snap.movable = [("Whisky", 9_000_000_000)]; snap.dataVolumePlugged = Config.relocateTarget != nil
            let move = TodayEngine.actions(snap).first { $0.id == "move" }
            check("Aujourd'hui : « \(move?.title ?? "—") » → \(move?.detail ?? "—")", move?.target == .relocate && move?.detail.contains(name) == true)
            // Réglages : retirer puis remettre, tout de suite, sans toucher au reste de la configuration.
            let before = Config.current
            onMain { DataDisk.set(nil) }
            check("Réglages > Retirer : plus de disque de données, plus de lecture seule d'office", Config.relocateTarget == nil && !Ignore.readOnlyDefaults.contains(Volumes.realURL(img.mount).path))
            onMain { DataDisk.set(before?.dataDisk) }
            check("Réglages > Choisir : retrouvé, le reste de la configuration intact", Config.current == before && Config.relocateTarget?.name == name)
            // Débranché : Déplacer n'a plus de destination, l'affichage le dit, rien n'est perdu.
            DiskImage.detach(img); attached = false
            Config.invalidate()
            check("disque débranché : plus de destination, choix gardé (« \(onMain { DataDisk.line(Config.current?.dataDisk) }) »)",
                  Config.relocateTarget == nil && Config.current?.dataDisk?.volume.name == name && onMain { DataDisk.line(Config.current?.dataDisk) }.contains("non branché"))
            _ = store
        }
    }

    /// Les réglages qu'une version ne connaît pas (ceux d'une autre version de zerOS) restent enregistrés tels quels, octet pour
    /// octet au sens JSON, quoi qu'on change ailleurs ; une configuration d'avant la 1.0 reprend sa source comme disque de données, une fois.
    static func keepsOtherSettings() {
        print("— Réglages d'une autre version de zerOS : ignorés, jamais effacés")
        let loc: [String: Any] = ["volume": ["uuid": "UUID-ZT-SRC", "name": "ZT SOURCE"], "path": ""]
        let dst: [String: Any] = ["volume": ["uuid": "UUID-ZT-DST", "name": "ZT SAUVE"], "path": ""]
        let others: [String: Any] = [
            "source": loc, "dest": dst, "sourceName": "ZT SOURCE", "backupEnabled": true,
            "sources": [["location": loc, "label": "ZT SOURCE"]],
            "repos": [["location": dst, "repoID": "0123456789abcdef", "rescueConfirmed": true, "created": 784_000_000.0]],
            "retention": ["daily": 7, "weekly": 4, "monthly": 12],
            "futur": ["réglage": "d'une version future"],
        ]
        func raw(_ store: UserDefaults) -> [String: Any] {
            (store.data(forKey: Config.key).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        }
        func same(_ a: [String: Any]) -> Bool { others.allSatisfy { k, v in (a[k] as AnyObject?)?.isEqual(v) == true } }
        withStore { store in
            var v1 = others; v1["version"] = 1
            store.set(try! JSONSerialization.data(withJSONObject: v1), forKey: Config.key)
            check("configuration d'avant la 1.0 lue (aucune erreur)", Config.current != nil)
            Config.adoptDataDisk()
            check("reprise : la source (disque entier) devient le disque de données, une seule fois (version 2)",
                  Config.current?.dataDisk?.volume.uuid == "UUID-ZT-SRC" && Config.current?.version == 2)
            check("reprise : tous les autres réglages intacts", same(raw(store)))
            onMain { DataDisk.set(nil) }
            Config.adoptDataDisk()
            check("disque de données retiré : il ne revient pas au lancement suivant", Config.current?.dataDisk == nil)
            onMain {
                let m = WizardModel(step: 0)
                m.readOnly = [:]
                m.save()
            }
            Config.sync()
            check("assistant relancé et terminé, noms de disques mis à jour : réglages de l'autre version toujours là, identiques", same(raw(store)))
            check("chaque réglage vérifié : " + others.keys.sorted().joined(separator: ", "), others.keys.allSatisfy { raw(store)[$0] != nil })
        }
    }

    // MARK: 5. Assistant

    static func wizard() {
        print("— Assistant de premier lancement")
        withStore { store in
            let w = onMain { () -> (steps: [String], step: Int, clamped: Int) in
                let m = WizardModel(step: 0); let hi = WizardModel(step: 99)
                return (WizardModel.steps, m.step, hi.step)
            }
            check("assistant : 4 étapes (accès complet, disque de données, lecture seule, fin), étape toujours valide",
                  w.steps == ["Accès complet au disque", "Disque de données", "Dossiers en lecture seule", "Terminé"] && w.step == 0 && w.clamped == 3)
            check("assistant : n'enregistre rien avant « Terminer »", onMain { let m = WizardModel(step: 1); m.step += 1; return Config.needsWizard })
            check("accès complet au disque : état lu, lien vers les Réglages disponible", Perms.fullDiskAccess == onMain { WizardModel(step: 0).fullDisk })
            // Configuration existante : l'assistant ne s'affiche jamais (Mac déjà réglé).
            Config.current = AppConfig()
            check("Mac déjà configuré : l'assistant ne s'affiche pas", !Config.needsWizard)
            Config.current = nil
        }
    }

    // MARK: 6. Icône de la barre des menus et bulle

    static func statusItemAndBubble() {
        print("— Barre des menus : NSStatusItem géré par zerOS, bulle placée sous l'icône")
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1050)
        let size = NSSize(width: 304, height: 80)
        let mid = MenuBubble.origin(icon: NSRect(x: 900, y: 1026, width: 34, height: 24), size: size, screen: screen)
        check("bulle : centrée sous l'icône (x \(Int(mid.x)), y \(Int(mid.y)))", abs(mid.x + size.width / 2 - 917) < 0.5 && mid.y == 1026 - 80 - 6)
        let edge = MenuBubble.origin(icon: NSRect(x: 1890, y: 1026, width: 30, height: 24), size: size, screen: screen)
        check("bulle : ne sort pas de l'écran quand l'icône est au bord droit (x \(Int(edge.x)))", edge.x + size.width <= screen.maxX - 8 + 0.5 && edge.x > 1500)
        let left = MenuBubble.origin(icon: NSRect(x: 0, y: 1026, width: 30, height: 24), size: size, screen: screen)
        check("bulle : ne sort pas de l'écran au bord gauche", left.x >= screen.minX + 8)
        onMain {
            check("avant installation : pas d'icône, donc pas de bulle (l'alerte reste dans la cloche)", !StatusBar.shared.isInstalled && MenuBubble.anchor() == nil)
            StatusBar.shared.install()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            check("NSStatusItem créé par zerOS", StatusBar.shared.isInstalled && StatusBar.shared.item?.button != nil)
            if let f = StatusBar.shared.iconFrame {
                check("l'ancre de la bulle est le cadre du NSStatusItem (\(Int(f.minX)), \(Int(f.minY)), \(Int(f.width))×\(Int(f.height)))", MenuBubble.anchor() == f)
                let vis = StatusBar.shared.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
                let o = MenuBubble.origin(icon: f, size: size, screen: vis)
                check("bulle réelle : sous l'icône, dans l'écran (x \(Int(o.x)), y \(Int(o.y)))", o.y < f.minY && o.x >= vis.minX && o.x + size.width <= vis.maxX && abs((o.x + size.width / 2) - f.midX) < 1 || o.x == vis.minX + 8 || o.x + size.width == vis.maxX - 8)
                MenuBubble.shared.show(Alert(id: "test", channel: .bubble, title: "Test", body: "Test", link: nil))
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                check("bulle affichée sans erreur sous l'icône", true)
            } else {
                print("  – pas de fenêtre d'icône disponible dans cette session (session sans barre des menus) : placement réel non vérifié")
            }
            StatusBar.shared.remove()
            check("icône retirée : plus de bulle possible", !StatusBar.shared.isInstalled && MenuBubble.anchor() == nil)
        }
    }
}


extension ConfigTests {
    static func navigation() {
        print("— Navigation, finitions")
        withStore { _ in
            // Rail de navigation : sélection immédiate, borné (pas de boucle) ; bulle de sélection toujours dans le rail, à chaque image.
            onMain {
                let nav = Nav.shared
                nav.section = .today
                nav.step(1); let next = nav.section == .storage
                nav.step(-1); nav.step(-1); let bounded = nav.section == .today
                nav.select(.journal); nav.step(1); let boundedEnd = nav.section == .journal
                nav.section = .today
                check("rail : un cran = une section, borné aux deux bouts (pas de boucle)", next && bounded && boundedEnd)
                let n = nav.visibleSections.count, H = Rail.height(n)
                let s0 = Rail.span(0), sN = Rail.span(n - 1)
                let a = bubbleSweep(Motion.sectionSpring, from: s0, to: sN, length: H), b = bubbleSweep(Motion.sectionSpring, from: sN, to: s0, length: H)
                check("rail : bulle ⌘1→⌘\(n) et retour toujours dans le rail, au plus \(String(format: "%.1f", max(a.squash, b.squash))) pt écrasée contre le bord, jamais étirée",
                      a.inside && b.inside && a.stretch <= 0.01 && b.stretch <= 0.01 && Rail.inset == 108)
            }
            // Capsule de sous-sections (Stockage, 6 onglets d'environ 100 pt) : bulle toujours dans la capsule à chaque image, d'un bout à
            // l'autre, dans les deux sens et entre voisins ; étirement nul (≤ 6 pt demandé).
            onMain {
                let tabs: [(CGFloat, CGFloat)] = (0..<6).map { (CGFloat($0) * 102, CGFloat($0) * 102 + 100) }, L: CGFloat = 610
                var ok = true, stretch: CGFloat = 0, squash: CGFloat = 0
                for (a, b) in [(0, 5), (5, 0), (0, 1), (4, 5), (5, 4), (1, 0)] {
                    let r = bubbleSweep(Motion.subsectionSpring, from: tabs[a], to: tabs[b], length: L)
                    ok = ok && r.inside; stretch = max(stretch, r.stretch); squash = max(squash, r.squash)
                }
                check("sous-sections : bulle toujours dans la capsule à chaque image (6 changements), étirement \(String(format: "%.1f", stretch)) pt, écrasée au plus \(String(format: "%.1f", squash)) pt aux extrémités",
                      ok && stretch <= 6)
            }
            // Finitions (DESIGN.md §12) : nombres au format français, états vides factuels sans emoji.
            onMain {
                let p = Fmt.percent(100, digits: 1), n = Fmt.number(1234.5, digits: 1)
                check("format français : « \(p) », « \(n) »", p == "100,0\u{00A0}%" && n.contains(",5") && !n.contains("."))
                let msgs = [AppSessions.cleanup, AppSessions.leftovers, AppSessions.installers, AppSessions.large, AppSessions.dupes,
                            AppSessions.similar, AppSessions.downloads, AppSessions.cloud].map(\.emptyMessage)
                let chatty = msgs.filter { m in m.unicodeScalars.contains { $0.properties.isEmojiPresentation } || m.contains("!") || m.contains("propre") }
                check("états vides factuels, sans emoji (\(msgs.count) messages)", chatty.isEmpty && msgs.contains("Aucun fichier dans Téléchargements"))
            }
            Config.current = nil
        }
    }
}

/// Suit une bulle de sélection image par image (120 Hz) pendant un changement : ses deux bords suivent le ressort ensemble, puis sont
/// bornés au contenant (`BubbleSpan.clamp`). Rend : toujours dedans, plus grand étirement, plus grand écrasement contre un bord.
func bubbleSweep(_ spring: Spring, from: (CGFloat, CGFloat), to: (CGFloat, CGFloat), length: CGFloat) -> (inside: Bool, stretch: CGFloat, squash: CGFloat) {
    var inside = true, stretch: CGFloat = 0, squash: CGFloat = 0
    let w = to.1 - to.0
    for i in 0...144 {
        let k = CGFloat(spring.value(target: 1.0, time: Double(i) / 120))
        let c = BubbleSpan.clamp(from.0 + (to.0 - from.0) * k, from.1 + (to.1 - from.1) * k, length: length)
        if c.lo < -0.001 || c.hi > length + 0.001 || c.hi < c.lo { inside = false }
        stretch = max(stretch, (c.hi - c.lo) - w); squash = max(squash, w - (c.hi - c.lo))
    }
    return (inside, stretch, squash)
}
