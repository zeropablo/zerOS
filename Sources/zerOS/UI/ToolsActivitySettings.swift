import SwiftUI
import AppKit
import ServiceManagement

// MARK: - My Activity

struct ActivityView: View {
    @ObservedObject var store = ActivityStore.shared
    let monitor = SystemMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            HStack(alignment: .top, spacing: Space.gap) {
                Grid(horizontalSpacing: Space.gap, verticalSpacing: Space.gap) {
                    GridRow {
                        stat("Espace libéré au total", Fmt.bytes(store.totalFreed), "externaldrive.badge.checkmark", "depuis la première utilisation")
                        stat("Ces 30 derniers jours", Fmt.bytes(store.freed(since: Date().addingTimeInterval(-30 * 86400))), "calendar",
                             "depuis le \(Fmt.date(Date().addingTimeInterval(-30 * 86400)))")
                    }
                    GridRow {
                        stat("Actions réalisées", "\(store.entries.count)", "checkmark.circle", "nettoyages, désinstallations, réparations")
                        stat("Temps gagné", store.minutesSaved >= 60 ? "\(store.minutesSaved / 60) h \(store.minutesSaved % 60) min" : "\(store.minutesSaved) min", "clock", "estimation")
                    }
                    GridRow { cloudStat.gridCellColumns(2) }
                }
            }
            Text("Historique").font(Typo.sectionTitle).padding(.top, 4)
            Deferred {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.entries.prefix(150)) { e in
                        HStack(spacing: 12) {
                            Text(e.module).fontWeight(.medium).frame(width: 150, alignment: .leading)
                            Text(e.text).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            Text(e.bytes > 0 ? Fmt.bytes(e.bytes) : "—").monospacedDigit().frame(width: 90, alignment: .trailing)
                            Text(Fmt.dateTime(e.date)).foregroundStyle(.secondary).frame(width: 150, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                        .lazyRow()
                    }
                }
            }
            .scrollEdgeFade()
            .overlay {
                if store.entries.isEmpty { EmptyState("Aucune action dans l'historique", symbol: "clock") }
            }
            }
            .frame(minHeight: 180)
        }
        .padding(Space.page)
    }

    var cloudStat: some View {
        let cloud = store.entries.filter { $0.module == "Nettoyage du cloud" }.reduce(0) { $0 + $1.bytes }
        return stat("Libéré par le nettoyage du cloud", Fmt.bytes(cloud), "icloud", "copies locales retirées, fichiers gardés en ligne")
    }

    func stat(_ t: String, _ v: String, _ s: String, _ footer: String) -> some View {
        Tile(title: t, value: v, footer: footer, symbol: s)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("menuEnabled") var menuEnabled = true
    @AppStorage("notificationsOn") var notificationsOn = true
    @AppStorage("watchTrash") var watchTrash = true
    @AppStorage("audioInterface") var audioInterface = ""
    @Local private var audioApps = Prefs.audioApps.joined(separator: ", ")
    @Local private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        TabView {
            Form {
                Section("Ouverture") {
                    Toggle("Afficher zerOS dans la barre des menus", isOn: $menuEnabled)
                    Toggle(Self.loginLabel, isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in
                            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { launchAtLogin = !on }
                        }
                }
                Section {
                    Toggle(Self.notificationsLabel, isOn: $notificationsOn)
                    Toggle("Proposer de supprimer les restes quand une app est jetée", isOn: $watchTrash)
                } header: { Text("Notifications") } footer: { Text("Le reste s'affiche dans une petite bulle sous l'icône de la barre des menus, qui disparaît seule.") }
                Section {
                    TextField("Interface audio suivie", text: $audioInterface, prompt: Text("Facultatif : les interfaces USB / Thunderbolt sont détectées"))
                    TextField("Apps audio suivies (séparées par des virgules)", text: $audioApps, prompt: Text("Facultatif"))
                } header: { Text("Audio (Santé)") }
                DataDiskSetting()
                Section {
                    Button("Relancer l'assistant de premier lancement…") { Wizard.show(forced: true) }
                } footer: { Text(Self.wizardFooter) }
            }
            .formStyle(.grouped)
            .onChange(of: audioApps) { _, v in Prefs.audioApps = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            .tabItem { Label("Général", systemImage: "gearshape") }

            ProtectionSettings()
                .tabItem { Label("Protection", systemImage: "lock.shield") }


            Form {
                Section {
                    LabeledContent {
                        Button("Ouvrir les réglages") { Perms.openFullDiskAccess() }
                    } label: {
                        Label { Text("Accès complet au disque") } icon: {
                            Image(systemName: Perms.Access.shared.fullDisk ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(Perms.Access.shared.fullDisk ? .green : .orange)
                        }
                        Text("Nécessaire pour nettoyer Mail, Safari, la Corbeille, les sauvegardes iPhone et lire les autorisations des apps.")
                    }
                    LabeledContent {
                        Text(SmartInsights.isAvailable ? "Disponible" : "Indisponible").foregroundStyle(.secondary)
                    } label: {
                        Label { Text("Smart Insights (Apple Intelligence)") } icon: {
                            Image(systemName: SmartInsights.isAvailable ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(SmartInsights.isAvailable ? .green : .secondary)
                        }
                        if !SmartInsights.isAvailable { Text(SmartInsights.unavailableReason) }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Autorisations", systemImage: "hand.raised") }

            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                Text("zerOS").font(Typo.hero)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))").foregroundStyle(.secondary)
                Text("Nettoyage sûr, stockage, apps et santé de votre Mac.").foregroundStyle(.secondary)
                Text("Rien n'est supprimé sans confirmation ; vos fichiers vont à la Corbeille.").font(Typo.detail).foregroundStyle(.secondary)
                Text("Mac Apple Silicon, macOS 15 ou plus récent.").font(Typo.detail).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tabItem { Label("À propos", systemImage: "info.circle") }
        }
        .frame(width: 580, height: 500)
    }

    static let loginLabel = "Ouvrir zerOS à l'ouverture de session"
    static let notificationsLabel = "Notifications macOS (seulement le critique : disque plein)"
    static let wizardFooter = "Reprend les étapes de la première ouverture : accès complet au disque, disque de données, dossiers en lecture seule. Rien n'est changé avant la fin."
}

/// Disque de données (« Déplacer ») : choisi, changé ou retiré tout de suite, indépendamment de toute autre fonction.
struct DataDiskSetting: View {
    @Local private var line = DataDisk.line(Config.current?.dataDisk)
    @Local private var chosen = Config.current?.dataDisk != nil
    @Local private var refused: String?

    var body: some View {
        Section {
            LabeledContent {
                HStack {
                    if chosen { Button("Retirer") { set(nil) } }
                    Button("Choisir…") { choose() }
                }
            } label: {
                Text(line)
                if let refused { Text(refused).foregroundStyle(.red) }
            }
        } header: { Text("Disque de données") } footer: {
            Text("Disque externe où Stockage > Déplacer propose de ranger les données lourdes d'apps. En lecture seule pour le nettoyage : rien n'y est jamais supprimé.")
        }
    }

    private func choose() {
        refused = DataDisk.choose()
        line = DataDisk.line(Config.current?.dataDisk)
        chosen = Config.current?.dataDisk != nil
    }

    private func set(_ loc: Location?) {
        DataDisk.set(loc)
        refused = nil
        line = DataDisk.line(loc)
        chosen = loc != nil
    }
}

/// Disk names and the two protection levels (read-only and blocked).
struct ProtectionSettings: View {
    @Local private var readOnly = Ignore.readOnlyUserPaths
    @Local private var ignored = Ignore.userPaths
    @Local private var extensions = Prefs.projectExtensions
    @Local private var devCaches = Prefs.ignoredDevCaches
    @Local private var newExtension = ""

    var body: some View {
        Form {
            Section {
                ForEach(Ignore.readOnlyDefaults, id: \.self) { p in
                    LabeledContent(display(p)) { Text(Self.role(p)).foregroundStyle(.secondary) }
                }
                ForEach(readOnly, id: \.self) { p in
                    LabeledContent(display(p)) {
                        Button("Retirer", systemImage: "minus.circle") { Ignore.removeReadOnly(p); readOnly = Ignore.readOnlyUserPaths }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                Button("Ajouter un dossier…") { pick { Ignore.addReadOnly($0) }; readOnly = Ignore.readOnlyUserPaths }
            } header: { Text("Lecture seule") } footer: {
                Text(Self.readOnlyFooter)
            }

            Section {
                ForEach(extensions, id: \.self) { e in
                    LabeledContent(".\(e)") {
                        Button("Retirer", systemImage: "minus.circle") { extensions.removeAll { $0 == e }; Prefs.projectExtensions = extensions }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Extension", text: $newExtension, prompt: Text("ex. : cpr"))
                        .onSubmit(addExtension)
                    Button("Ajouter", action: addExtension).disabled(cleaned(newExtension).isEmpty)
                }
                Button("Rétablir les valeurs par défaut") { extensions = Prefs.defaultProjectExtensions; Prefs.projectExtensions = extensions }
                    .disabled(extensions == Prefs.defaultProjectExtensions)
            } header: { Text("Fichiers de projet") } footer: {
                Text("Fichiers et paquets en lecture seule où qu'ils soient, ainsi que les dossiers qui les contiennent : Logic, GarageBand, Ableton, After Effects, Premiere, TouchDesigner, Photoshop, Final Cut, Photos.")
            }

            Section {
                ForEach(devCaches, id: \.self) { p in
                    LabeledContent(display(p)) {
                        Button("Retirer", systemImage: "minus.circle") { devCaches.removeAll { $0 == p }; Prefs.ignoredDevCaches = devCaches }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                Button("Ajouter un dossier…") { pick { p in if !devCaches.contains(p) { devCaches.append(p) } }; Prefs.ignoredDevCaches = devCaches }
            } header: { Text("Caches de développement ignorés") } footer: {
                Text("Dossiers de compilation de vos propres projets : jamais proposés au nettoyage (les supprimer obligerait à tout recompiler).")
            }

            Section {
                ForEach(ignored, id: \.self) { p in
                    LabeledContent(display(p)) {
                        Button("Retirer", systemImage: "minus.circle") { Ignore.remove(p); ignored = Ignore.userPaths }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                Button("Ajouter…") { pick { Ignore.add($0) }; ignored = Ignore.userPaths }
            } header: { Text("Bloqué") } footer: {
                Text("Jamais lus ni affichés. Toujours bloqués : ~/.claude, ~/.ssh, trousseaux, dossiers système.")
            }
        }
        .formStyle(.grouped)
    }

    private func cleaned(_ e: String) -> String {
        e.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private func addExtension() {
        let e = cleaned(newExtension)
        guard !e.isEmpty, !extensions.contains(e) else { return }
        extensions.append(e); Prefs.projectExtensions = extensions; newExtension = ""
    }

    private func display(_ p: String) -> String { p.replacingOccurrences(of: FS.home.path, with: "~") }

    /// Pourquoi ce chemin est en lecture seule d'office.
    static func role(_ p: String) -> String {
        if let d = Config.relocateTarget, Volumes.realURL(d.url).path == p || d.url.standardizedFileURL.path == p { return "disque de données" }
        return "disque de données"
    }

    static let readOnlyFooter = "Analysés et affichés, jamais cochés ni supprimés. Le disque de données l'est toujours. Un dossier qui contient un élément protégé ne peut pas non plus être supprimé."

    private func pick(_ add: (String) -> Void) {
        let pnl = NSOpenPanel()
        pnl.canChooseDirectories = true
        pnl.allowsMultipleSelection = true
        if pnl.runModal() == .OK { pnl.urls.forEach { add($0.path) } }
    }
}
