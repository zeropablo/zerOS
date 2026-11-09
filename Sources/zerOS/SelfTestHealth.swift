import Foundation
import AppKit
import SwiftUI

/// Alertes : chaque règle est déclenchée par un état simulé et son canal (notification macOS ou bulle) est vérifié.
enum AlertTests {
    static func run() {
        print("\n=== Alertes et notifications ===")
        var fails = 0
        func check(_ name: String, _ ok: Bool) { print("  \(ok ? "✓" : "✗") \(name)"); if !ok { fails += 1 } }
        let GB: Int64 = 1_000_000_000
        let now = Date()
        func ids(_ i: AlertInput) -> [String] { Alerts.evaluate(i, now: now).map(\.id) }
        func ch(_ id: String) -> AlertChannel? { Alerts.rule(id)?.channel }

        // Répartition des canaux (SPEC.md).
        let macOS = Set(Alerts.rules.filter { $0.channel == .macOS }.map(\.id))
        check("macOS seulement pour : disque presque plein", macOS == ["disk"])
        check("en bulle : mémoire, Corbeille, corbeille d'un disque, reste d'app, profil ; aucune autre règle",
              ["lowmem", "trash", "drivetrash", "app-trash", "profile"].allSatisfy { ch($0) == .bubble } && Alerts.rules.count == 6)
        var i = AlertInput(diskFree: 8 * GB, diskTotal: 100 * GB, pressure: 1)
        check("disque interne à 8 % libre → « disque » (macOS)", ids(i) == ["disk"] && Alerts.evaluate(i, now: now)[0].channel == .macOS)
        i.diskFree = 15 * GB
        check("disque à 15 % libre → rien", ids(i).isEmpty)
        i = AlertInput(diskFree: 50 * GB, diskTotal: 100 * GB, pressure: 4, swapUsed: 6 * GB)
        check("pression mémoire critique → « lowmem » (bulle)", ids(i) == ["lowmem"] && Alerts.evaluate(i, now: now)[0].channel == .bubble)
        i.pressure = 2
        check("pression élevée seulement → rien", ids(i).isEmpty)
        i.trashSize = 6 * GB
        check("Corbeille de 6 Go → « trash » (bulle) ; 4 Go → rien", ids(i) == ["trash"] && { var j = i; j.trashSize = 4 * GB; return ids(j).isEmpty }())
        i.trashSize = 0; i.driveTrash = ["Disque A": 2 * GB, "Disque B": GB / 2]
        check("corbeille d'un disque externe : 2 Go sur A → alerte propre à A, 0,5 Go sur B → rien", ids(i) == ["drivetrash.Disque A"] && Alerts.evaluate(i, now: now)[0].channel == .bubble)
        i.driveTrash = [:]; i.profileProblem = "Cache After Effects : le volume « CACHES » est absent."
        check("cache Adobe vers un volume absent → « profile » (bulle)", ids(i) == ["profile"] && Alerts.evaluate(i, now: now)[0].channel == .bubble)

        // Événements.
        check("app dans la Corbeille → bulle", Alerts.appInTrash(name: "Truc", files: 3, bytes: GB).channel == .bubble)

        // Cadence.
        var last: [String: Date] = [:]
        let disk = Alert(id: "disk", channel: .macOS, title: "", body: "")
        check("cadence : 1 / 24 h (la 2e le même jour est retenue, une autre après 25 h passe)",
              Alerts.due([disk], now: now, last: &last).count == 1 && Alerts.due([disk], now: now.addingTimeInterval(3600), last: &last).isEmpty
              && Alerts.due([disk], now: now.addingTimeInterval(25 * 3600), last: &last).count == 1)
        let mem = Alert(id: "lowmem", channel: .bubble, title: "", body: "")
        check("cadence mémoire : 1 / h", Alerts.due([mem], now: now, last: &last).count == 1 && Alerts.due([mem], now: now.addingTimeInterval(1800), last: &last).isEmpty
              && Alerts.due([mem], now: now.addingTimeInterval(3700), last: &last).count == 1)
        let a = Alert(id: "drivetrash.A", channel: .bubble, title: "", body: ""), b = Alert(id: "drivetrash.B", channel: .bubble, title: "", body: "")
        check("cadence par disque : A retenu, B passe", Alerts.due([a], now: now, last: &last).count == 1 && Alerts.due([a, b], now: now, last: &last).map(\.id) == ["drivetrash.B"])
        print(fails == 0 ? "  Tout est bon." : "  \(fails) échec(s).")
    }
}

/// Santé : lecture des disques (exemples + réel), audio, profil de machine.
enum HealthTests {
    static func run() {
        print("\n=== Santé ===")
        var fails = 0
        func check(_ name: String, _ ok: Bool) { print("  \(ok ? "✓" : "✗") \(name)"); if !ok { fails += 1 } }
        func nvme(temp: Int, used: Int, spare: Int = 100, errors: Int = 0, smart: String = "Verified") -> [String: Any] {
            ["BusProtocol": "PCI-Express", "SolidState": true, "SMARTStatus": smart, "TotalSize": 2_000_000_000_000,
             "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": ["TEMPERATURE": temp, "PERCENTAGE_USED": used, "AVAILABLE_SPARE": spare, "MEDIA_ERRORS_0": errors,
                                                             "POWER_ON_HOURS_0": 1515, "DATA_UNITS_WRITTEN_0": 9_000_117] as [String: Any]]
        }
        let ok = HealthChecks.parseDisk(nvme(temp: 305, used: 1), name: "X", role: .data)
        check("NVMe : température 305 K → \(String(format: "%.1f", ok.temperature ?? 0)) °C, usure 1 %, 1 515 h, vert",
              abs((ok.temperature ?? 0) - 31.85) < 0.01 && ok.percentUsed == 1 && ok.powerOnHours == 1515 && ok.level == .green && ok.smartReadable)
        check("NVMe : 9 000 117 unités écrites → 4,6 To", ok.written == 9_000_117 * 512_000)
        check("NVMe : usure 85 % → orange ; 75 °C → orange", HealthChecks.parseDisk(nvme(temp: 305, used: 85), name: "X", role: .data).level == .orange
              && HealthChecks.parseDisk(nvme(temp: 348, used: 1), name: "X", role: .data).level == .orange)
        check("NVMe : erreurs de support → rouge ; réserve 5 % → rouge ; SMART « Failing » → rouge",
              HealthChecks.parseDisk(nvme(temp: 305, used: 1, errors: 2), name: "X", role: .data).level == .red
              && HealthChecks.parseDisk(nvme(temp: 305, used: 1, spare: 5), name: "X", role: .data).level == .red
              && HealthChecks.parseDisk(nvme(temp: 305, used: 1, smart: "Failing"), name: "X", role: .data).level == .red)
        let usb = HealthChecks.parseDisk(["BusProtocol": "USB", "SMARTStatus": "Not Supported", "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": [String: Any]()], name: "USB", role: .other)
        check("disque USB (SMART « Not Supported ») → non lisible, sans température, niveau inconnu", !usb.smartReadable && usb.temperature == nil && usb.level == .unknown)

        // Relevé réel (lecture seule).
        let t = Date()
        let disks = HealthChecks.readDisks()
        print("  Disques lus en \(String(format: "%.1f", Date().timeIntervalSince(t))) s :")
        for d in disks { print("    · \(d.name) [\(d.bus)] SMART \(d.smart ?? "—") · \(d.temperature.map { String(format: "%.0f °C", $0) } ?? "température non lisible") · \(d.level)") }
        check("disque interne lu : SMART lisible, température lue", disks.first { $0.role == .internalDisk }.map { $0.smartReadable && $0.temperature != nil } == true)

        // Profil de machine.
        let exists: (String) -> Bool = { $0 == "/Volumes/PRESENT" }
        let problems = HealthChecks.volumeProblems([("Cache After Effects", "/Volumes/CACHES/Adobe/After Effects"), ("Cache média", "/Volumes/PRESENT/Media"), ("Défaut", "/Users/x/Library/Caches")], volumeExists: exists)
        check("profil : cache sur un volume absent signalé (CACHES), volume présent et chemin interne ignorés", problems.count == 1 && problems[0].contains("CACHES") && problems[0].contains("absent"))

        // Audio.
        let fm = FileManager.default
        let hal = fm.temporaryDirectory.appendingPathComponent("zerOS-hal-\(UUID().uuidString)")
        try? fm.createDirectory(at: hal.appendingPathComponent(HealthChecks.blackHoleDrivers.0), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: hal) }
        let r = HealthChecks.readAudio(interface: "Interface Inexistante 99", apps: ["AppAudio", "Autre"], halFolder: hal.path, running: ["Finder", "AppAudio"])
        check("audio : BlackHole 2ch installé, 16ch absent, AppAudio lancé, autre app non lancée, interface absente → nil",
              r.blackHole2 && !r.blackHole16 && r.runningApps["AppAudio"] == true && r.runningApps["Autre"] == false && r.interface == nil)
        print("  Audio réel : sortie par défaut \(r.defaultOutput.map { "\($0.name) \(HealthChecks.rateText($0.rate))" } ?? "—"), \(r.devices.count) périphérique(s)")
        check("audio : sortie par défaut et fréquence lues", r.defaultOutput.map { $0.rate > 0 } == true)
        check("fréquences : 48 kHz, 44,1 kHz", HealthChecks.rateText(48000) == "48 kHz" && HealthChecks.rateText(44100) == "44,1 kHz")
        check("module Audio masqué sans interface ni BlackHole, visible avec l'un des deux",
              !HealthChecks.audioVisible(interface: "  ", blackHoleInstalled: false) && HealthChecks.audioVisible(interface: "InterfaceX", blackHoleInstalled: false) && HealthChecks.audioVisible(interface: "", blackHoleInstalled: true))
        fails += HealthLoadTests.run()
        print(fails == 0 ? "  Tout est bon." : "  \(fails) échec(s).")
    }
}

/// Santé 1.0.0 : la page restait sur « Lecture des disques… ». Ces contrôles reproduisent les causes possibles : sortie de processus
/// volumineuse, commande qui ne rend pas la main (signal ignoré, petit-enfant qui garde le tube), échec de lancement, et la page elle-même
/// affichée hors écran avec des données qui arrivent pendant le fondu d'arrivée (la vraie cause).
enum HealthLoadTests {
    static func run() -> Int {
        var fails = 0
        func check(_ name: String, _ ok: Bool) { print("  \(ok ? "✓" : "✗") \(name)"); if !ok { fails += 1 } }
        func timed<T>(_ f: () -> T) -> (T, Double) { let t = Date(); let v = f(); return (v, Date().timeIntervalSince(t)) }

        // Processus.
        let (big, tBig) = timed { Shell.run("/bin/sh", ["-c", "head -c 2000000 /dev/zero | tr '\\0' a"], timeout: 10) }
        check("sortie de 2 Mo (bien plus que le tampon d'un tube, 64 Ko) lue en entier, sans interblocage (\(String(format: "%.1f", tBig)) s)",
              big.ok && big.out.utf8.count == 2_000_000 && tBig < 5)
        let (term, tTerm) = timed { Shell.run("/bin/sh", ["-c", "trap '' TERM; sleep 15"], timeout: 1) }
        check("commande qui ignore l'arrêt : rend la main après le délai (\(String(format: "%.1f", tTerm)) s, attendu < 4 s), en échec", !term.ok && tTerm < 4)
        let (child, tChild) = timed { Shell.run("/bin/sh", ["-c", "sleep 15 & echo debut"], timeout: 1) }
        check("petit-enfant qui garde le tube ouvert : rend la main après le délai (\(String(format: "%.1f", tChild)) s, attendu < 4 s)", tChild < 4)
        let (missing, tMissing) = timed { Shell.run("/nonexistent/zerOS-outil-absent", [], timeout: 5) }
        check("programme absent : échec immédiat", !missing.ok && tMissing < 1)

        // Disques : chacun son délai, lus en même temps ; un disque qui ne répond pas est « Information indisponible », les autres normaux.
        let plist = { (name: String) in
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>BusProtocol</key><string>USB</string>"
            + "<key>SMARTStatus</key><string>Not Supported</string><key>VolumeName</key><string>\(name)</string></dict></plist>"
        }
        let drives = ["/Volumes/A-TEST", "/Volumes/LENT-TEST", "/Volumes/ECHEC-TEST"].map {
            DeviceInfo(name: ($0 as NSString).lastPathComponent, kind: "drive", detail: "", battery: nil, url: URL(fileURLWithPath: $0), free: 1, total: 2, external: true)
        }
        let (read, tRead) = timed {
            HealthChecks.readDisks(drives: drives, timeout: 1) { path, t in
                switch path {
                case "/Volumes/LENT-TEST": return Shell.run("/bin/sh", ["-c", "trap '' TERM; sleep 15"], timeout: t)
                case "/Volumes/ECHEC-TEST": return Shell.run("/bin/sh", ["-c", "echo 'Could not find disk' >&2; exit 1"], timeout: t)
                default: return Shell.run("/bin/echo", [plist(path)], timeout: t)
                }
            }
        }
        let byName = Dictionary(read.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        check("disques : un disque qui ne répond pas ne retient pas les autres (\(String(format: "%.1f", tRead)) s, attendu < 5 s)", tRead < 5)
        check("disques : disque normal lu, disque muet et disque en échec « Information indisponible », disque interne présent",
              byName["A-TEST"]?.unavailable == false && byName["A-TEST"]?.bus == "USB" && byName["LENT-TEST"]?.unavailable == true
              && byName["ECHEC-TEST"]?.unavailable == true && byName["Disque interne"] != nil && read.count == 4)

        // La page Santé, affichée hors écran (fenêtre transparente hors des écrans), avec un relevé factice.
        let fake = [DiskHealth(name: fakeName, role: .other, bus: "USB", smart: "Not Supported")]
        fails += page("données arrivées pendant le fondu d'arrivée", expect: fakeName, endAfter: 0.6) { fake }
        fails += page("données arrivées après le fondu", expect: fakeName, endAfter: 0.3) { Thread.sleep(forTimeInterval: 1); return fake }
        let savedDeadline = HealthModel.deadline
        HealthModel.deadline = 1.5
        fails += page("relevé qui ne rend jamais la main", expect: "Information indisponible", endAfter: 0.3) { Thread.sleep(forTimeInterval: 10); return fake }
        HealthModel.deadline = savedDeadline
        return fails
    }

    static let fakeName = "DISQUE-TEST-ZEROS"

    /// Construit `HealthView` dans une fenêtre invisible pendant un fondu de page (`Settle.begin`), avec le relevé factice `reader`,
    /// termine le fondu après `endAfter`, puis attend (4 s au plus) que la ligne `expect` apparaisse (`HealthView.probe`).
    private static func page(_ name: String, expect: String, endAfter: Double, reader: @escaping @Sendable () -> [DiskHealth]) -> Int {
        let saved = HealthChecks.diskReader
        HealthChecks.diskReader = reader
        defer { HealthChecks.diskReader = saved }
        var ctx: (window: NSWindow, previous: AppSection, token: Int)!
        let seen = Seen()
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                HealthView.probe = { seen.add($0) }
                let previous = Nav.shared.section
                Nav.shared.section = .health
                let token = Settle.shared.begin()
                let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 820, height: 1400), styleMask: [.borderless], backing: .buffered, defer: false)
                w.alphaValue = 0
                w.isReleasedWhenClosed = false
                w.contentView = NSHostingView(rootView: HealthView().frame(width: 820, height: 1400))
                w.orderFrontRegardless()
                ctx = (w, previous, token)
            }
        }
        Thread.sleep(forTimeInterval: endAfter)
        DispatchQueue.main.sync { MainActor.assumeIsolated { Settle.shared.end(ctx.token) } }
        var text = ""
        let limit = Date().addingTimeInterval(4)
        repeat {
            Thread.sleep(forTimeInterval: 0.3)
            text = seen.all.joined(separator: " → ")
        } while !text.contains(expect) && Date() < limit
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                ctx.window.orderOut(nil); ctx.window.contentView = nil
                HealthView.probe = nil
                Nav.shared.section = ctx.previous
            }
        }
        var fails = 0
        let ok = text.contains(expect)
        func check(_ name: String, _ ok: Bool) { print("  \(ok ? "✓" : "✗") \(name)") }
        check("page Santé, \(name) : « \(expect) » s'affiche, le chargement se termine (lignes apparues : \(text.isEmpty ? "aucune" : text))", ok)
        if !ok { fails += 1 }
        return fails
    }

    /// Lignes de disque apparues, dans l'ordre.
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }
}
