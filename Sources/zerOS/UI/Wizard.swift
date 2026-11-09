import SwiftUI
import AppKit

/// Assistant de premier lancement : accès complet au disque, disque de données (facultatif), dossiers en lecture seule (étapes : `WizardModel.steps`).
/// S'ouvre seul quand aucune configuration n'existe (jamais sur un Mac déjà réglé), et se relance depuis Réglages. Rien n'est enregistré
/// avant « Terminer ».
@MainActor
final class Wizard: NSObject, NSWindowDelegate {
    static let shared = Wizard()
    private var window: NSWindow?
    private var finished = false
    var isOpen: Bool { window?.isVisible == true }

    static func show(forced: Bool) { shared.show(forced: forced) }

    func show(forced: Bool = false, step: Int = 0) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        finished = false
        let model = WizardModel(step: step)
        let host = NSHostingController(rootView: WizardView(model: model) { [weak self] in self?.finish() }.accessibilityRoot())
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable]
        w.title = "Bienvenue dans zerOS"
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 560, height: 520))
        w.center()
        w.delegate = self
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        finished = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        // Fermé sans terminer sur un Mac sans configuration : zerOS reste utilisable, l'assistant reviendra au prochain lancement.
        if !finished, Config.needsWizard { MainWindow.shared.openIgnoringWizard() }
        if finished { MainWindow.shared.show() }
    }
}

@MainActor
final class WizardModel: ObservableObject {
    static let steps = ["Accès complet au disque", "Disque de données", "Dossiers en lecture seule", "Terminé"]

    @Published var step: Int
    @Published var fullDisk = Perms.fullDiskAccess
    @Published var draft: AppConfig
    @Published var refused: [String] = []
    /// Dossiers proposés (Musique, Films) et dossiers ajoutés : cochés = en lecture seule.
    @Published var readOnly: [String: Bool] = [:]
    @Published var extra: [String] = []

    static var suggestions: [(title: String, path: String)] {
        [("Musique", FS.h("Music").path), ("Films", FS.h("Movies").path)].filter { FS.exists(URL(fileURLWithPath: $0.1)) }
    }

    init(step: Int) {
        self.step = min(max(step, 0), Self.steps.count - 1)
        // Captures : `--wizard-empty` montre l'assistant comme sur un Mac neuf, même si ce Mac est déjà configuré.
        let fresh = CommandLine.arguments.contains("--wizard-empty")
        draft = fresh ? AppConfig() : (Config.current ?? AppConfig())
        let current = fresh ? [] : Ignore.readOnlyUserPaths
        let configured = !fresh && Config.current != nil
        for s in Self.suggestions { readOnly[s.path] = configured ? current.contains(s.path) : true }
        extra = current.filter { p in !Self.suggestions.contains { $0.path == p } }
        for p in extra { readOnly[p] = true }
        // Captures : `--wizard-data=/Volumes/X` préremplit les choix (sans rien enregistrer).
        let args = CommandLine.arguments
        func arg(_ k: String) -> URL? { args.first { $0.hasPrefix(k) }.map { URL(fileURLWithPath: String($0.dropFirst(k.count))) } }
        if let u = arg("--wizard-data=") { chooseDataDisk(u) }
    }

    var dataDiskLine: String { DataDisk.line(draft.dataDisk) }

    /// Disque de données : un disque externe entier (sinon refus expliqué, rien n'est changé).
    func chooseDataDisk(_ picked: URL? = nil) {
        guard let u = picked ?? FolderPicker.pick("Choisissez le disque externe où ranger les données lourdes d'apps.", prompt: "Choisir ce disque") else { return }
        switch Config.dataDiskChoice(u) {
        case .success(let loc): draft.dataDisk = loc; refused = []
        case .failure(let e): refused = [e.text]
        }
    }


    func addFolder() {
        guard let u = FolderPicker.pick("Choisissez un dossier à protéger : zerOS l'analysera sans jamais y supprimer quoi que ce soit.",
                                        prompt: "Protéger", start: FS.home) else { return }
        let p = u.standardizedFileURL.path
        if !extra.contains(p), !Self.suggestions.contains(where: { $0.path == p }) { extra.append(p) }
        readOnly[p] = true
    }

    /// Enregistre la configuration et les dossiers en lecture seule choisis (les autres dossiers déjà protégés sont conservés).
    func save() {
        Config.current = draft
        let chosen = readOnly.filter(\.value).map(\.key)
        let offered = Set(Self.suggestions.map(\.path) + extra)
        let kept = Ignore.readOnlyUserPaths.filter { !offered.contains($0) }
        Ignore.readOnlyUserPaths = kept + chosen.sorted()
        Config.sync()
    }
}

struct WizardView: View {
    @ObservedObject var model: WizardModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Étape \(model.step + 1) sur \(WizardModel.steps.count)").font(Typo.caption).foregroundStyle(.secondary)
            Text(WizardModel.steps[model.step]).font(Typo.value)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch WizardModel.steps[model.step] {
                    case "Accès complet au disque": fullDisk
                    case "Disque de données": dataDisk
                    case "Dossiers en lecture seule": readOnly
                    default: summary
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            buttons
        }
        .padding(Space.page)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.fullDisk = Perms.fullDiskAccess }
    }

    // MARK: Étapes

    var fullDisk: some View {
        Group {
            Text("Pour analyser et nettoyer Mail, Safari, la Corbeille et les sauvegardes d'iPhone, et lire les autorisations des apps, zerOS a besoin de l'accès complet au disque. Sans lui, ces parties restent vides ; le reste fonctionne.")
            Label(model.fullDisk ? "Accès complet au disque : accordé" : "Accès complet au disque : pas encore accordé",
                  systemImage: model.fullDisk ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(model.fullDisk ? .green : .orange)
            Button("Ouvrir les Réglages Système") { Perms.openFullDiskAccess() }
            Text("Dans Réglages Système > Confidentialité et sécurité > Accès complet au disque, ajoutez zerOS avec le bouton + puis activez-le. macOS peut proposer de quitter et rouvrir zerOS : acceptez, l'assistant reprendra ici.")
                .font(Typo.detail).foregroundStyle(.secondary)
        }
    }

    var dataDisk: some View {
        Group {
            Text("Disque externe où ranger les données lourdes d'apps (bibliothèques de sons, bouteilles Whisky, jeux…) : Stockage > Déplacer donne la marche à suivre vers ce disque. zerOS ne déplace rien lui-même et n'y supprime jamais rien : ce disque est en lecture seule pour le nettoyage. Étape facultative.")
            GroupBox("Disque de données") {
                HStack {
                    Text(model.dataDiskLine).frame(maxWidth: .infinity, alignment: .leading)
                    if model.draft.dataDisk != nil { Button("Retirer") { model.draft.dataDisk = nil; model.refused = [] } }
                    Button("Choisir…") { model.chooseDataDisk() }
                }.padding(4)
            }
            if !model.refused.isEmpty {
                ForEach(model.refused, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
        }
    }


    func row(_ text: String, _ button: String, _ action: @escaping () -> Void) -> some View {
        HStack { Text(text).frame(maxWidth: .infinity, alignment: .leading); Button(button, action: action) }.padding(4)
    }

    var readOnly: some View {
        Group {
            Text("Ces dossiers seront analysés et affichés, mais zerOS n'y supprimera jamais rien : ni cochés d'office, ni sélectionnables pour un nettoyage. Utile pour la musique, les vidéos et les projets.")
            ForEach(WizardModel.suggestions, id: \.path) { s in toggle(s.title, s.path) }
            ForEach(model.extra, id: \.self) { p in toggle((p as NSString).lastPathComponent, p) }
            Button("Ajouter un dossier…") { model.addFolder() }
            Text(Self.alreadyProtected)
                .font(Typo.detail).foregroundStyle(.secondary)
        }
    }

    static let alreadyProtected = "Les fichiers de projet (Logic, Ableton, After Effects, Premiere, Photoshop…) sont déjà protégés où qu'ils soient, et le disque de données aussi."

    func toggle(_ title: String, _ path: String) -> some View {
        Toggle(isOn: Binding(get: { model.readOnly[path] ?? false }, set: { model.readOnly[path] = $0 })) {
            Text(title)
            Text(path.replacingOccurrences(of: FS.home.path, with: "~"))
        }
    }

    var summary: some View {
        Group {
            LabeledContent("Accès complet au disque", value: model.fullDisk ? "accordé" : "pas accordé (réglable plus tard dans Réglages)")
            LabeledContent("Disque de données", value: model.dataDiskLine)
            LabeledContent("Lecture seule", value: {
                let p = model.readOnly.filter(\.value).map { ($0.key as NSString).lastPathComponent }.sorted()
                return p.isEmpty ? "aucun dossier" : p.joined(separator: ", ")
            }())
            Text("Tout se modifie ensuite dans Réglages, et cet assistant peut être relancé depuis Réglages > Général.").font(Typo.detail).foregroundStyle(.secondary)
        }
    }

    // MARK: Boutons

    var buttons: some View {
        HStack {
            if model.step > 0 { Button("Précédent") { model.step -= 1 } }
            Spacer()
            if model.step < WizardModel.steps.count - 1 {
                Button("Continuer") { model.step += 1 }.keyboardShortcut(.defaultAction)
            } else {
                Button("Terminer") { model.save(); done() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Disque de données (assistant, Réglages, Déplacer) : affichage et choix.
enum DataDisk {
    /// Choix par la fenêtre d'ouverture, enregistré tout de suite. Renvoie la raison d'un refus (nil : choisi, ou annulé).
    @MainActor static func choose() -> String? {
        guard let u = FolderPicker.pick("Choisissez le disque externe où ranger les données lourdes d'apps.", prompt: "Choisir ce disque") else { return nil }
        switch Config.dataDiskChoice(u) {
        case .success(let loc): set(loc); return nil
        case .failure(let e): return e.text
        }
    }

    static func set(_ loc: Location?) {
        var c = Config.current ?? AppConfig()
        c.dataDisk = loc
        Config.current = c
    }

    static func line(_ loc: Location?) -> String {
        guard let loc else { return "Aucun" }
        let vols = Volumes.mounted()
        guard let u = loc.resolve(in: vols), FS.responds(u),
              let rv = try? u.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
              let free = rv.volumeAvailableCapacity, let total = rv.volumeTotalCapacity else { return "« \(loc.label(in: vols)) » : non branché" }
        return "« \(loc.label(in: vols)) » · \(Fmt.bytes(Int64(free))) libres sur \(Fmt.bytes(Int64(total)))"
    }
}
