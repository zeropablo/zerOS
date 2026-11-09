import AppKit
import QuartzCore

/// Mesure de fluidité (`--frame-log`, jamais en fonctionnement normal) : un `CADisplayLink` sur l'écran de la fenêtre note l'intervalle
/// entre deux images et la page affichée dans `FS.support/frames.txt`. Une image « perdue » = un intervalle
/// supérieur à 1,5 fois la durée d'une image de l'écran.
@MainActor
final class FrameLog: NSObject {
    static let shared = FrameLog()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var liveTask: Task<Void, Never>?
    private var lines: [String] = []
    private var flushTask: Task<Void, Never>?

    func start(on window: NSWindow?) {
        guard link == nil, let screen = window?.screen ?? NSScreen.main else { return }
        let l = screen.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        // Fenêtre fermée : la mesure se met en pause (sinon elle réveillerait l'app 120 fois par seconde et fausserait la mesure au repos).
        liveTask = Task { @MainActor [weak self] in
            if #available(macOS 26, *) {
                for await live in Observations({ @MainActor in Nav.shared.live }) { self?.link?.isPaused = !live; self?.last = 0; if !live { self?.flush() } }
            } else {
                for await live in Observed.values({ Nav.shared.live }) { self?.link?.isPaused = !live; self?.last = 0; if !live { self?.flush() } }
            }
        }
        try? FileManager.default.removeItem(at: FS.support.appendingPathComponent("frames.txt"))
        lines = ["# t(s) intervalle(ms) durée_image(ms) - section sous-vue"]
        flushTask = Task { [weak self] in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000_000); self?.flush() }
        }
    }

    @objc private func tick(_ l: CADisplayLink) {
        let t = l.timestamp
        defer { last = t }
        // Fenêtre fermée : la mesure s'arrête (sinon elle réveillerait l'app 120 fois par seconde et fausserait la mesure au repos).
        guard last > 0, Nav.shared.visible else { return }
        let nav = Nav.shared
        let sub = Router.shared.sub[nav.section]?.rawValue ?? "-"
        lines.append(String(format: "%.4f %.2f %.2f %.1f %@ %@", t, (t - last) * 1000, (l.targetTimestamp - l.timestamp) * 1000,
                            0.0, nav.section.rawValue, sub))
    }

    /// Repère dans le journal (début d'une transition du parcours de test).
    func mark(_ label: String) {
        lines.append(String(format: "# %.4f %@", CACurrentMediaTime(), label.replacingOccurrences(of: " ", with: "_")))
    }

    private func flush() {
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: "\n") + "\n"
        lines = []
        let url = FS.support.appendingPathComponent("frames.txt")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
}

/// Parcours de test (`--demo-tour`, jamais en fonctionnement normal) : rail (molette), sections, sous-sections, Arborescence (zoom avant et
/// arrière), analyse du Nettoyage avec chargement ; chaque geste est marqué dans `frames.txt` pour compter les images perdues.
@MainActor
enum DemoTour {
    static func run() {
        let nav = Nav.shared, r = Router.shared, log = FrameLog.shared
        let steps: [(Double, String, () -> Void)] = [
            (3, "rail_molette", { nav.step(1) }),
            (5, "rail_molette", { nav.step(1) }),
            (6.5, "rail_molette", { nav.step(-1) }),
            (8, "rail_molette", { nav.step(-1) }),
            (11, "section_stockage", { nav.select(.storage) }),
            (13, "sous_arborescence", { r.sub[.storage] = .spaceLens }),
            (17, "zoom_avant", { let m = StorageModel.shared; if let k = m.focus?.children.first(where: { $0.isDir && !$0.children.isEmpty }) { m.focus = k } }),
            (20, "zoom_arriere", { let m = StorageModel.shared; if let p = m.root { m.focus = p } }),
            (23, "sous_donnees_systeme", { r.sub[.storage] = .systemData }),
            (27, "sous_nettoyage", { r.sub[.storage] = .cleanup }),
            (29, "analyse_nettoyage", { AppSessions.cleanup.scan() }),
            (50, "section_apps", { nav.select(.apps) }),
            (56, "section_sante", { nav.select(.health) }),
            (60, "section_journal", { nav.select(.journal) }),
            (64, "section_aujourdhui", { nav.select(.today) }),
            (70, "rail_molette", { nav.step(1) }),
            (76, "sous_arborescence", { r.sub[.storage] = .spaceLens }),
            (80, "sous_nettoyage", { r.sub[.storage] = .cleanup }),
            (84, "section_aujourdhui", { nav.select(.today) }),
        ]
        for (t, label, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { log.mark(label); action() }
        }
    }
}

/// Parcours des sections (`--demo-sections`, jamais en fonctionnement normal) : chaque section deux fois (première visite puis retour),
/// Stockage > Arborescence, Mon désordre > Téléchargements ; une transition toutes les 3 s, marquée dans `frames.txt`
/// (`Tools/images_perdues.swift` en tire la plus longue image figée et le pourcentage d'images perdues par transition).
@MainActor
enum DemoSections {
    static func run() {
        let nav = Nav.shared, r = Router.shared, log = FrameLog.shared
        let order: [(String, () -> Void)] = [
            ("section_stockage", { nav.select(.storage) }), ("section_apps", { nav.select(.apps) }),
            ("section_sante", { nav.select(.health) }),
            ("section_journal", { nav.select(.journal) }), ("section_aujourdhui", { nav.select(.today) }),
            ("section_stockage", { nav.select(.storage) }), ("sous_arborescence", { r.sub[.storage] = .spaceLens }),
            ("section_apps", { nav.select(.apps) }), ("section_stockage", { nav.select(.storage) }),
            ("sous_desordre", { r.sub[.storage] = .clutter }), ("onglet_telechargements", { r.tabs[.clutter] = "downloads" }),
            ("section_sante", { nav.select(.health) }),
            ("section_journal", { nav.select(.journal) }), ("section_aujourdhui", { nav.select(.today) }),
            ("section_apps", { nav.select(.apps) }), ("section_stockage", { nav.select(.storage) }),
            ("section_aujourdhui", { nav.select(.today) }),
        ]
        var steps = order
        for (i, (label, action)) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4 + Double(i) * 3) { log.mark(label); action() }
        }
    }
}

/// Test de 5 min (`--demo-test5`, jamais en fonctionnement normal), 2 min fenêtre ouverte (à lancer avec `--close-after=120`) : clics
/// rapides entre sections dès l'ouverture (toutes les 0,25 s : chaque animation est interrompue par la suivante), puis Stockage > Données
/// système et Arborescence, Apps > Démarrage et Arrière-plan, deux fois chacun (même chemin que la capsule de sous-sections), sous-sections
/// rapides, zoom de l'arborescence, sections au rythme normal. Chaque geste est marqué dans `frames.txt` (et `--hang-log` note les blocages).
@MainActor
enum DemoTest5 {
    static func run() {
        let nav = Nav.shared, r = Router.shared, log = FrameLog.shared
        var steps: [(Double, String, () -> Void)] = []
        var t = 2.0
        func add(_ dt: Double, _ label: String, _ a: @escaping () -> Void) { steps.append((t, label, a)); t += dt }
        func sub(_ m: Module) -> () -> Void { { Settle.shared.transition { r.sub[.storage] = m } } }
        func tab(_ id: String) -> () -> Void { { Settle.shared.transition { r.tabs[.applications] = id } } }
        for s in [AppSection.storage, .apps, .health, .journal, .today, .apps, .storage, .today] { add(0.25, "rapide_\(s.rawValue)") { nav.select(s) } }
        t += 2
        for pass in 1...2 {
            add(2, "section_stockage") { nav.select(.storage) }
            add(3, "sous_donnees_systeme_\(pass)", sub(.systemData))
            add(3, "sous_arborescence_\(pass)", sub(.spaceLens))
            add(2, "section_apps") { nav.select(.apps) }
            add(3, "onglet_demarrage_\(pass)", tab("login"))
            add(3, "onglet_arriere_plan_\(pass)", tab("background"))
        }
        add(2, "section_stockage") { nav.select(.storage) }
        for m in [Module.systemData, .spaceLens, .relocate, .systemData, .cleanup, .spaceLens] { add(0.25, "sous_rapide_\(m.rawValue)", sub(m)) }
        t += 2
        add(2.5, "zoom_avant") { let m = StorageModel.shared; if let k = m.focus?.children.first(where: { $0.isDir && !$0.children.isEmpty }) { m.focus = k } }
        add(2.5, "zoom_arriere") { let m = StorageModel.shared; if let p = m.root { m.focus = p } }
        add(2, "section_apps") { nav.select(.apps) }
        for id in ["login", "background", "uninstall", "login", "background"] { add(0.25, "onglet_rapide_\(id)", tab(id)) }
        t += 2
        for s in [AppSection.today, .storage, .apps, .health, .journal, .health, .apps, .storage, .today] { add(1.5, "section_\(s.rawValue)") { nav.select(s) } }
        for (at, label, action) in steps where at < 118 {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { log.mark(label); action() }
        }
    }
}
