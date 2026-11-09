import Foundation
import AppKit
import CoreAudio

/// Relevés de Santé (SPEC.md, §4). Tout est lu sans outil externe : `diskutil info -plist` (SMART et, pour les disques NVMe, le journal
/// SMART avec la température), CoreAudio, quelques fichiers. Les fonctions `parse…` / `…Problems` sont pures, donc testées sur des
/// exemples ; les fonctions `read…` ne font que lire.
struct DiskHealth: Identifiable, Sendable {
    enum Role: Sendable { case data, internalDisk, other }
    var id: String { name }
    var name: String
    var role: Role
    var bus: String
    var solidState: Bool?
    var smart: String?
    var temperature: Double?
    /// NVMe : part d'usure consommée (0-100), blocs de réserve restants (%), erreurs de support, heures de marche, écritures totales.
    var percentUsed: Int?
    var spare: Int?
    var mediaErrors: Int?
    var powerOnHours: Int?
    var written: Int64?
    var free: Int64 = 0
    var total: Int64 = 0
    /// `diskutil` n'a pas répondu à temps (ou a échoué) : « Information indisponible ».
    var unavailable = false

    /// Ce que macOS permet de lire sans smartctl : SMART seulement si le disque l'expose (pas à travers la plupart des boîtiers USB).
    var smartReadable: Bool { smart != nil && smart != "Not Supported" }

    enum Level: Int, Sendable { case green, orange, red, unknown }

    /// Vert : SMART vérifié et aucune alerte. Rouge : SMART en échec, erreurs de support, ou réserve épuisée. Orange : usure ≥ 80 % ou
    /// température ≥ 70 °C. Inconnu : rien de lisible (disque USB mécanique).
    var level: Level {
        guard smartReadable else { return .unknown }
        if smart != "Verified" { return .red }
        if (mediaErrors ?? 0) > 0 { return .red }
        if let s = spare, s < 10 { return .red }
        if (percentUsed ?? 0) >= 80 || (temperature ?? 0) >= 70 { return .orange }
        return .green
    }
}

enum HealthChecks {
    // MARK: Disques

    /// Interprète le plist de `diskutil info`. La température NVMe est donnée en kelvins.
    static func parseDisk(_ p: [String: Any], name: String, role: DiskHealth.Role) -> DiskHealth {
        var d = DiskHealth(name: name, role: role, bus: p["BusProtocol"] as? String ?? "—", solidState: p["SolidState"] as? Bool,
                           smart: p["SMARTStatus"] as? String)
        d.total = (p["TotalSize"] as? Int64) ?? Int64(p["TotalSize"] as? Int ?? 0)
        if let k = p["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any], !k.isEmpty {
            func int(_ key: String) -> Int? { (k[key] as? Int) ?? (k[key] as? NSNumber)?.intValue }
            if let t = int("TEMPERATURE"), t > 200 { d.temperature = Double(t) - 273.15 }
            d.percentUsed = int("PERCENTAGE_USED")
            d.spare = int("AVAILABLE_SPARE")
            d.mediaErrors = int("MEDIA_ERRORS_0")
            d.powerOnHours = int("POWER_ON_HOURS_0")
            // Une unité = 512 000 octets (spécification NVMe).
            d.written = int("DATA_UNITS_WRITTEN_0").map { Int64($0) * 512_000 }
        }
        return d
    }

    /// Relevé des disques utilisé par la page Santé (remplaçable par l'autotest).
    nonisolated(unsafe) static var diskReader: @Sendable () -> [DiskHealth] = { readDisks() }

    /// Délai maximal de `diskutil info` pour un disque. Au-delà, ce disque est montré « Information indisponible », les autres normalement.
    static let diskTimeout: Double = 10

    /// Disque interne, puis volumes externes montés (sauf images disque), rangés par rôle (`rank`). Les disques sont lus en même
    /// temps, chacun avec son délai : un disque qui ne répond pas ne retient pas les autres. `drives` / `run` : remplacés par l'autotest.
    static func readDisks(drives: [DeviceInfo]? = nil, timeout: Double = diskTimeout,
                          run: @escaping @Sendable (_ path: String, _ timeout: Double) -> Shell.Result = { Shell.run("/usr/sbin/diskutil", ["info", "-plist", $0], timeout: $1) }) -> [DiskHealth] {
        func info(_ path: String) -> [String: Any]? {
            let r = run(path, timeout)
            guard r.ok, let d = r.out.data(using: .utf8) else { return nil }
            return (try? PropertyListSerialization.propertyList(from: d, options: [], format: nil)) as? [String: Any]
        }
        let external = (drives ?? SystemMonitor.mountedDrives()).filter { $0.external && !$0.readOnly && $0.url != nil }
        let found = Found(count: external.count + 1)
        DispatchQueue.concurrentPerform(iterations: external.count + 1) { i in
            if i == 0 {
                var d = info("/").map { parseDisk($0, name: "Disque interne", role: .internalDisk) }
                    ?? DiskHealth(name: "Disque interne", role: .internalDisk, bus: "—", unavailable: true)
                (d.total, d.free, _) = SystemMonitor.disk()
                found.set(i, d)
                return
            }
            let v = external[i - 1], u = v.url!
            let p = info(u.path)
            if let p, p["Internal"] as? Bool == true || (p["BusProtocol"] as? String) == "Disk Image" { return }
            let vol = Volumes.containing(u)
            let role: DiskHealth.Role = vol.map(Config.isDataDisk) == true ? .data : .other
            var d = p.map { parseDisk($0, name: v.name, role: role) } ?? DiskHealth(name: v.name, role: role, bus: "—", unavailable: true)
            d.free = v.free; d.total = v.total
            found.set(i, d)
        }
        return found.all.sorted { rank($0.role) < rank($1.role) }
    }

    /// Résultats des lectures simultanées (un emplacement par disque).
    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [DiskHealth?]
        init(count: Int) { items = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ d: DiskHealth) { lock.lock(); items[i] = d; lock.unlock() }
        var all: [DiskHealth] { lock.lock(); defer { lock.unlock() }; return items.compactMap { $0 } }
    }

    /// Exécute `work` hors du fil appelant et rend son résultat, ou nil s'il n'a pas fini dans `seconds` (le travail continue alors
    /// seul et son résultat est ignoré). La suite est reprise exactement une fois, sur tous les chemins.
    static func bounded<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let once = Once()
            DispatchQueue.global(qos: .utility).async { let v = work(); if once.claim() { c.resume(returning: v) } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { if once.claim() { c.resume(returning: nil) } }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    private static func rank(_ r: DiskHealth.Role) -> Int {
        switch r {
        case .data: 1; case .internalDisk: 2; case .other: 3
        }
    }

    // MARK: Audio

    struct AudioDevice: Identifiable, Sendable {
        var id: UInt32
        var name: String
        var rate: Double
        var output: Bool
        var input: Bool
        /// Type de connexion CoreAudio ('usb ', 'thun', '1394', 'pci ', 'bltn', 'virt'…).
        var transport: UInt32 = 0

        /// Interface audio externe (USB, Thunderbolt, FireWire, PCI) : détectée sans rien supposer sur sa marque.
        var isExternalInterface: Bool {
            [Self.code("usb "), Self.code("thun"), Self.code("1394"), Self.code("pci ")].contains(transport) && (output || input)
        }
        static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    }

    struct AudioReport: Sendable {
        var devices: [AudioDevice] = []
        var defaultOutput: AudioDevice?
        var interface: AudioDevice?
        /// Interfaces audio externes détectées (sans réglage).
        var interfaces: [AudioDevice] = []
        var blackHole2 = false
        var blackHole16 = false
        var runningApps: [String: Bool] = [:]
    }

    static let blackHoleDrivers = ("BlackHole2ch.driver", "BlackHole16ch.driver")

    static func readAudio(interface: String = Prefs.audioInterface, apps: [String] = Prefs.audioApps,
                          halFolder: String = "/Library/Audio/Plug-Ins/HAL", running: [String]? = nil) -> AudioReport {
        var r = AudioReport()
        r.devices = audioDevices()
        let defOut = defaultOutputID()
        r.defaultOutput = r.devices.first { $0.id == defOut }
        let wanted = interface.trimmingCharacters(in: .whitespaces).lowercased()
        r.interfaces = r.devices.filter(\.isExternalInterface)
        if !wanted.isEmpty { r.interface = r.devices.first { $0.name.lowercased().contains(wanted) } }
        let fm = FileManager.default
        r.blackHole2 = fm.fileExists(atPath: halFolder + "/" + blackHoleDrivers.0)
        r.blackHole16 = fm.fileExists(atPath: halFolder + "/" + blackHoleDrivers.1)
        let names = (running ?? NSWorkspace.shared.runningApplications.compactMap(\.localizedName)).map { $0.lowercased() }
        for a in apps { r.runningApps[a] = names.contains { $0.contains(a.lowercased()) } }
        return r
    }

    /// Le module Audio est masqué quand rien n'est configuré, installé ni détecté (SPEC.md : un module sans matériel se masque).
    static func audioVisible(interface: String, blackHoleInstalled: Bool, detected: Bool = false) -> Bool {
        !interface.trimmingCharacters(in: .whitespaces).isEmpty || blackHoleInstalled || detected
    }

    private static func prop(_ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputID() -> UInt32 {
        var a = prop(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr ? id : 0
    }

    private static func channels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var a = prop(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, buf) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func audioDevices() -> [AudioDevice] {
        var a = prop(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var na = prop(kAudioObjectPropertyName)
            var cf: Unmanaged<CFString>?
            var ns = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &na, 0, nil, &ns, &cf) == noErr, let name = cf?.takeRetainedValue() as String? else { return nil }
            var ta = prop(kAudioDevicePropertyTransportType)
            var transport = UInt32(0); var ts = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(id, &ta, 0, nil, &ts, &transport)
            var ra = prop(kAudioDevicePropertyNominalSampleRate)
            var rate = Float64(0); var rs = UInt32(MemoryLayout<Float64>.size)
            _ = AudioObjectGetPropertyData(id, &ra, 0, nil, &rs, &rate)
            return AudioDevice(id: id, name: name, rate: rate, output: channels(id, scope: kAudioObjectPropertyScopeOutput) > 0,
                               input: channels(id, scope: kAudioObjectPropertyScopeInput) > 0, transport: transport)
        }
    }

    static func rateText(_ hz: Double) -> String {
        hz <= 0 ? "—" : (hz.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(hz / 1000)) kHz" : Fmt.number(hz / 1000, digits: 1) + " kHz")
    }

    /// Relance le démon audio (mot de passe administrateur). Coupe le son une seconde.
    static func restartAudio() -> Bool { Shell.admin("killall coreaudiod").ok }

    // MARK: Profil de machine (caches Adobe)

    /// Un dossier de cache dans `/Volumes/<X>/…` dont le volume `<X>` n'est pas monté.
    static func volumeProblems(_ paths: [(label: String, path: String)], volumeExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        paths.compactMap { l, p in
            let parts = p.split(separator: "/")
            guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
            return volumeExists("/Volumes/" + parts[1]) ? nil : "\(l) : le volume « \(parts[1]) » est absent (\(p))."
        }
    }

    static func readProfileProblem() -> String? {
        var paths: [(String, String)] = []
        if let ae = CacheScan.afterEffectsPrefs() { paths.append(("Cache After Effects", ae.folder.path)) }
        let pp = CacheScan.premierePrefs()
        if let m = pp.mediaCache { paths.append(("Cache média Premiere Pro", m.path)) }
        if let m = pp.mediaCacheDatabase { paths.append(("Base du cache Premiere Pro", m.path)) }
        if let m = pp.previewFolder { paths.append(("Fichiers de prévisualisation Premiere Pro", m.path)) }
        let p = volumeProblems(paths)
        return p.isEmpty ? nil : p.joined(separator: " ")
    }
}

extension Prefs {
    /// Interface audio suivie en plus de celles qui sont détectées (nom partiel). Vide par défaut.
    static var audioInterface: String {
        get { store.string(forKey: "audioInterface") ?? "" }
        set { store.set(newValue, forKey: "audioInterface") }
    }
    /// Apps dont Santé dit si elles sont lancées (audio). Aucune par défaut.
    static var audioApps: [String] {
        get { store.stringArray(forKey: "audioApps") ?? [] }
        set { store.set(newValue, forKey: "audioApps") }
    }
}

