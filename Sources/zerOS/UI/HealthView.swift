import SwiftUI
import AppKit

/// État de la page Santé. Objet observé (Observation) : la page lit ces valeurs dans son bloc différé (`Deferred { form }`), donc dans le
/// `body` d'une autre vue. Avec de simples `@Local` de `HealthView` (1.0.0), des valeurs posées pendant le fondu d'arrivée n'étaient
/// jamais redessinées : « Lecture des disques… » sans fin. Ici chaque vue qui lit une propriété est redessinée quand elle change.
@MainActor @Observable
final class HealthModel {
    var disks: [DiskHealth]?
    var audio: HealthChecks.AudioReport?
    var profile: String?
    var restarting = false
    var restartNote: String?
    @ObservationIgnored private(set) var loadedAt: Date?
    @ObservationIgnored private var loading = false

    /// Délai maximal du relevé des disques (chaque disque a en plus son propre délai, `HealthChecks.diskTimeout`). Au-delà, la page
    /// affiche « Information indisponible » : jamais de chargement sans fin. Réduit par l'autotest.
    nonisolated(unsafe) static var deadline: Double = 20

    /// Disques d'abord (posés dès qu'ils sont lus), puis audio et profil. Tout est lu hors du fil principal.
    func load() {
        guard !loading else { return }
        loading = true
        let deadline = Self.deadline
        Task.detached(priority: .utility) { [self] in
            let d = await HealthChecks.bounded(deadline) { HealthChecks.diskReader() }
            await MainActor.run { Settle.shared.whenShown(.health) { self.disks = d ?? [] } }
            let a = await HealthChecks.bounded(10) { HealthChecks.readAudio() }
            let p = await HealthChecks.bounded(10) { HealthChecks.readProfileProblem() }
            await MainActor.run { Settle.shared.whenShown(.health) { self.audio = a; self.profile = p ?? nil } }
            await MainActor.run { self.loading = false; self.loadedAt = Date() }
        }
    }
}

/// Santé (SPEC.md, §4) : mémoire, disques, audio, batterie (MacBook), profil de machine. Les réparations manuelles sont l'onglet voisin.
struct HealthView: View {
    /// Autotest seulement : reçoit le nom de chaque ligne de disque qui apparaît (ou « Lecture des disques… »). Nil en usage normal.
    @MainActor static var probe: ((String) -> Void)?
    let m = SystemMonitor.shared
    @Local private var model = HealthModel()

    var body: some View {
        Deferred { form }
        .pageActions {
            Button { model.load() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }.help("Actualiser")
        }
        // Relu à chaque retour dans Santé, au plus toutes les 30 s (le bouton Actualiser relit tout de suite).
        // Chiffres de mémoire en direct (toutes les 2 s) seulement pendant que Santé est affichée.
        .onShow({
            SystemMonitor.shared.setLive("health", true)
            if model.loadedAt.map({ Date().timeIntervalSince($0) > 30 }) ?? true { model.load() }
        }, hide: { SystemMonitor.shared.setLive("health", false) })
    }

    var form: some View {
        Form {
            MemorySection()
            disksSection
            if let audio = model.audio, HealthChecks.audioVisible(interface: Prefs.audioInterface, blackHoleInstalled: audio.blackHole2 || audio.blackHole16, detected: !audio.interfaces.isEmpty) { audioSection(audio) }
            if let b = m.battery, Machine.hasBattery { battery(b) }
            Section("Profil de machine") {
                if let p = model.profile { Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                else { Label("Aucun cache Adobe ne pointe vers un volume absent.", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    func color(_ l: Level) -> Color { l == .green ? .green : (l == .orange ? .orange : .red) }
    func dot(_ c: Color) -> some View { Circle().fill(c).frame(width: 10, height: 10) }

    // MARK: Disques

    var disksSection: some View {
        Section {
            if let disks = model.disks {
                ForEach(disks) { d in disk(d).onAppear { HealthView.probe?(d.name) } }
                if disks.isEmpty {
                    Text("Information indisponible : les disques n'ont pas répondu à temps. Réessayez avec Actualiser.").foregroundStyle(.secondary)
                        .onAppear { HealthView.probe?("Information indisponible") }
                }
            } else { HStack { LiquidRing(size: 18); Text("Lecture des disques…").foregroundStyle(.secondary) }.onAppear { HealthView.probe?("Lecture des disques…") } }
        } header: { Text("Disques") } footer: {
            Text("Lu sans outil externe (diskutil). SMART et température ne sont lisibles que sur les disques NVMe branchés directement ou en Thunderbolt/USB4 ; la plupart des boîtiers USB ne transmettent rien. smartctl n'est pas installé : zerOS n'en dépend pas.")
        }
    }

    func disk(_ d: DiskHealth) -> some View {
        let lvl: Color = d.level == .green ? .green : (d.level == .orange ? .orange : (d.level == .red ? .red : .gray))
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                dot(lvl)
                Text(d.name).fontWeight(.semibold)
                Spacer()
                Text(role(d)).font(Typo.caption).foregroundStyle(.secondary)
            }
            if d.unavailable {
                LabeledContent("État", value: "Information indisponible")
                Text("Le disque n'a pas répondu à temps (\(Int(HealthChecks.diskTimeout)) s). Réessayez avec Actualiser.").font(Typo.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent("Connexion", value: d.bus + (d.solidState == true ? " · SSD" : (d.solidState == false ? " · disque dur" : "")))
                LabeledContent("État SMART", value: d.smartReadable ? (d.smart == "Verified" ? "Vérifié" : (d.smart ?? "—")) : "Non lisible")
            }
            if let t = d.temperature { LabeledContent("Température", value: Fmt.number(t) + " °C") } else if d.smartReadable == false && !d.unavailable { LabeledContent("Température", value: "Non lisible") }
            if let u = d.percentUsed { LabeledContent("Usure", value: Fmt.percent(Double(u))) }
            if let s = d.spare { LabeledContent("Blocs de réserve", value: Fmt.percent(Double(s))) }
            if let e = d.mediaErrors { LabeledContent("Erreurs de support", value: "\(e)") }
            if let h = d.powerOnHours { LabeledContent("Heures de marche", value: "\(h) h") }
            if let w = d.written { LabeledContent("Écrit au total", value: Fmt.bytes(w)) }
            if d.total > 0 { LabeledContent("Libre", value: "\(Fmt.bytes(d.free)) sur \(Fmt.bytes(d.total))") }
        }
        .padding(.vertical, 4)
    }

    func role(_ d: DiskHealth) -> String {
        switch d.role {
        case .data: "Disque de données"
        case .internalDisk: "Disque interne"
        case .other: "Disque externe"
        }
    }


    // MARK: Audio

    func audioSection(_ a: HealthChecks.AudioReport) -> some View {
        Section {
            let name = Prefs.audioInterface.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                LabeledContent("Interface « \(name) »") {
                    HStack { dot(a.interface != nil ? .green : .orange); Text(a.interface.map { "Détectée · \(HealthChecks.rateText($0.rate))" } ?? "Non détectée") }
                }
            }
            ForEach(a.interfaces) { d in
                LabeledContent("Interface détectée") { HStack { dot(.green); Text("\(d.name) · \(HealthChecks.rateText(d.rate))") } }
            }
            LabeledContent("Sortie par défaut", value: a.defaultOutput.map { "\($0.name) · \(HealthChecks.rateText($0.rate))" } ?? "—")
            if a.blackHole2 { LabeledContent("BlackHole 2ch") { HStack { dot(.green); Text("Installé") } } }
            if a.blackHole16 { LabeledContent("BlackHole 16ch") { HStack { dot(.green); Text("Installé") } } }
            ForEach(Prefs.audioApps, id: \.self) { app in
                LabeledContent(app) { HStack { dot(a.runningApps[app] == true ? .green : .gray); Text(a.runningApps[app] == true ? "Lancé" : "Non lancé") } }
            }
            HStack {
                Button(model.restarting ? "Redémarrage…" : "Redémarrer l'audio") {
                    let model = self.model
                    model.restarting = true; model.restartNote = nil
                    Task.detached {
                        let ok = HealthChecks.restartAudio()
                        await MainActor.run {
                            model.restarting = false
                            model.restartNote = ok ? "Audio redémarré." : "Annulé (mot de passe refusé)."
                            if ok { ActivityStore.shared.log(module: "Santé", text: "Audio redémarré (coreaudiod)", bytes: 0) }
                            model.load()
                        }
                    }
                }.disabled(model.restarting)
                if let n = model.restartNote { Text(n).foregroundStyle(.secondary) }
            }
        } header: { Text("Audio") } footer: {
            Text("Redémarrer l'audio relance le service système coreaudiod (mot de passe administrateur) : le son se coupe une seconde. L'interface et les apps suivies se règlent dans Réglages.")
        }
    }

    // MARK: Batterie

    func battery(_ b: BatteryInfo) -> some View {
        Section("Batterie") {
            LabeledContent("Charge", value: Fmt.percent(Double(b.percent)) + (b.charging ? " · en charge" : (b.pluggedIn ? " · branchée" : "")))
            LabeledContent("Santé") { HStack { dot(b.health < 70 ? .red : (b.health < 80 ? .orange : .green)); Text(Fmt.percent(Double(b.health)) + " de la capacité d'origine") } }
            LabeledContent("Cycles de charge", value: "\(b.cycles)")
            LabeledContent("Température", value: Fmt.number(b.temperature, digits: 1) + " °C")
        }
    }
}

// MARK: Mémoire

/// Seule partie de Santé qui suit le relevé de 2 s : sa propre vue, pour que le reste du formulaire ne se recalcule pas à chaque relevé.
struct MemorySection: View {
    let m = SystemMonitor.shared
    var body: some View {
        let ratio = m.memTotal > 0 ? Double(m.swapUsed) / Double(m.memTotal) : 0
        let level: Level = max(m.pressure >= 4 ? .red : (m.pressure >= 2 ? .orange : .green),
                               ratio >= Thresholds.swapRedRatio ? .red : (ratio >= Thresholds.swapOrangeRatio ? .orange : .green))
        return Section("Mémoire") {
            LabeledContent("Pression") { HStack { dot(color(level)); Text(m.pressure >= 4 ? "Critique" : (m.pressure >= 2 ? "Élevée" : "Normale")) } }
            LabeledContent("Utilisée", value: "\(Fmt.mem(m.memUsed)) sur \(Fmt.mem(m.memTotal))")
            LabeledContent("Échange (swap)", value: Fmt.mem(m.swapUsed))
            LabeledContent("Pic d'échange depuis l'ouverture de zerOS", value: Fmt.mem(m.swapPeak))
            // Les courbes ne se remplissent que pendant que Santé ou le panneau est affiché (relevé toutes les 2 s).
            LabeledContent("Mémoire utilisée") { Sparkline(values: m.memHistory, color: .blue).frame(width: 220, height: 28) }
            LabeledContent("Échange") { Sparkline(values: m.swapHistory, color: .orange).frame(width: 220, height: 28) }
        }
    }

    func color(_ l: Level) -> Color { l == .green ? .green : (l == .orange ? .orange : .red) }
    func dot(_ c: Color) -> some View { Circle().fill(c).frame(width: 10, height: 10) }
}
