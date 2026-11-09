import Foundation
import AppKit
import IOKit
import IOKit.ps
import Darwin

// MARK: - Processes

struct ProcInfo: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let path: String
    let cpu: Double
    let memory: Int64
    let pids: [Int32]
}

enum Processes {
    /// One entry per process.
    static func snapshot() -> [ProcInfo] {
        let r = Shell.run("/bin/ps", ["-Ao", "pid=,pcpu=,rss=,comm="])
        return r.out.components(separatedBy: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rss = Int64(parts[2]) else { return nil }
            let path = String(parts[3])
            return ProcInfo(name: URL(fileURLWithPath: path).lastPathComponent, path: path, cpu: cpu, memory: rss * 1024, pids: [pid])
        }
    }

    /// Helpers are rolled up into the app they belong to.
    static func byApp() -> [ProcInfo] {
        var agg: [String: (String, Double, Int64, [Int32])] = [:]
        for p in snapshot() {
            let name: String
            if let r = p.path.range(of: ".app/") {
                name = URL(fileURLWithPath: String(p.path[..<r.lowerBound])).lastPathComponent
            } else { name = p.name }
            var a = agg[name] ?? (p.path, 0, 0, [])
            a.1 += p.cpu; a.2 += p.memory; a.3 += p.pids
            agg[name] = a
        }
        return agg.map { ProcInfo(name: $0.key, path: $0.value.0, cpu: $0.value.1, memory: $0.value.2, pids: $0.value.3) }
    }
}

// MARK: - Snapshots

struct BatteryInfo: Equatable {
    var percent: Int
    var charging: Bool
    var pluggedIn: Bool
    var minutesLeft: Int?
    var cycles: Int
    var health: Int
    var temperature: Double
}

struct DeviceInfo: Identifiable, Hashable {
    var id: String { kind + name }
    let name: String
    let kind: String      // bluetooth, drive
    let detail: String
    let battery: Int?
    let url: URL?
    /// Volumes only: free / total bytes, external (not the internal disk) and read-only (mounted disk images…).
    var free: Int64 = 0
    var total: Int64 = 0
    var external = false
    var readOnly = false
}

@MainActor @Observable
final class SystemMonitor {
    static let shared = SystemMonitor()

    var cpu: Double = 0
    var cpuHistory: [Double] = Array(repeating: 0, count: 40)
    var memTotal: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    var memUsed: Int64 = 0
    var memApp: Int64 = 0
    var memWired: Int64 = 0
    var memCompressed: Int64 = 0
    var memCache: Int64 = 0
    var pressure: Int = 1          // 1 normal, 2 warning, 4 critical
    var swapUsed: Int64 = 0
    /// Plus grand échange vu depuis l'ouverture de zerOS (échantillons faits quand une fenêtre est visible ou sur événement de pression).
    var swapPeak: Int64 = 0
    /// Courbes de Santé : alimentées seulement pendant que la fenêtre ou le panneau est visible (jamais au repos).
    var memHistory: [Double] = Array(repeating: 0, count: 60)
    var swapHistory: [Double] = Array(repeating: 0, count: 60)
    var diskTotal: Int64 = 0
    var diskFree: Int64 = 0
    var diskFreeStrict: Int64 = 0
    var trashSize: Int64 = 0
    var smart: String = "—"
    var netIn: Double = 0
    var netOut: Double = 0
    var netHistory: [Double] = Array(repeating: 0, count: 40)
    var connected = true
    var battery: BatteryInfo?
    var uptime: TimeInterval = 0
    var topCPU: [ProcInfo] = []
    var topMem: [ProcInfo] = []
    var devices: [DeviceInfo] = []
    var speedTest: String?
    var speedTesting = false

    var driveTrash: [String: Int64] = [:]

    @ObservationIgnored private var prevTicks: [UInt64]?
    @ObservationIgnored private var prevNet: [String: (UInt32, UInt32)] = [:]
    @ObservationIgnored private var prevNetDate = Date()
    @ObservationIgnored private var fast: Timer?
    @ObservationIgnored private var slow: Timer?
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var started = false
    /// Open windows and panels showing live figures (main window, menu bar panel).
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var idleTicks = 0
    @ObservationIgnored private var lastDevices = Date.distantPast
    /// Écrans qui affichent les chiffres en direct (Santé affichée, panneau de la barre des menus) : seuls eux justifient un relevé toutes les 2 s.
    @ObservationIgnored private var live: Set<String> = []

    /// Live figures only while someone looks at them: Santé shown or the menu bar panel open samples every 2 s (heavy data every 30 s);
    /// a visible window showing another page, every 30 s (Aujourd'hui only needs disk, swap, uptime);
    /// with every window closed, one cheap tick every 2 min (disk, alerts) and devices every 30 min.
    /// Memory pressure and the Trash are event-driven (no polling, no Trash walk on a timer).
    func start() {
        guard !started else { return }
        started = true
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        src.setEventHandler { Task { @MainActor in SystemMonitor.shared.pressureChanged() } }
        src.resume()
        pressureSource = src
        sampleMemory()
        refreshTrash()
        reschedule()
    }

    func attach() { viewers += 1; if viewers == 1 { reschedule() } }
    func detach() { viewers = max(0, viewers - 1); if viewers == 0 { reschedule() } }
    var isVisible: Bool { viewers > 0 }
    /// Idempotent : `setLive("health", true)` deux fois ne compte qu'une fois.
    func setLive(_ who: String, _ on: Bool) {
        let before = !live.isEmpty
        if on { live.insert(who) } else { live.remove(who) }
        if before != !live.isEmpty { reschedule() }
    }

    private func reschedule() {
        guard started else { return }
        fast?.invalidate(); slow?.invalidate()
        fast = nil; slow = nil
        if isVisible {
            tickFast()
            tickSlow()
            if !live.isEmpty { fast = Self.timer(2, tolerance: 0.5) { $0.tickFast() } }
            slow = Self.timer(30, tolerance: 5) { m in if m.live.isEmpty { m.tickFast() }; m.tickSlow() }
        } else {
            idleTick()
            slow = Self.timer(120, tolerance: 30) { $0.idleTick() }
        }
    }

    private static func timer(_ interval: TimeInterval, tolerance: TimeInterval, _ tick: @escaping @MainActor (SystemMonitor) -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { _ in Task { @MainActor in tick(SystemMonitor.shared) } }
        t.tolerance = tolerance
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private func pressureChanged() {
        sampleMemory()
        checkAlerts()
    }

    func tickFast() {
        cpu = sampleCPU()
        cpuHistory = Array((cpuHistory + [cpu]).suffix(40))
        sampleMemory()
        memHistory = Array((memHistory + [Double(memUsed)]).suffix(60))
        swapHistory = Array((swapHistory + [Double(swapUsed)]).suffix(60))
        sampleNet()
        uptime = Self.bootUptimeMinute()
    }

    /// Window closed: disk and uptime (two cheap system calls), devices and external Trash bins every 30 min.
    private func idleTick() {
        (diskTotal, diskFree, diskFreeStrict) = Self.disk()
        uptime = Self.bootUptimeMinute()
        if Date().timeIntervalSince(lastDevices) > 1800 { refreshDevices() } else { checkAlerts() }
    }

    func tickSlow() {
        Task.detached(priority: .utility) {
            let disk = Self.disk()
            let bat = Self.batteryInfo()
            let procs = Processes.byApp()
            await MainActor.run {
                let m = SystemMonitor.shared
                (m.diskTotal, m.diskFree, m.diskFreeStrict) = disk
                m.battery = bat
                m.topCPU = Array(procs.sorted { $0.cpu > $1.cpu }.prefix(5))
                m.topMem = Array(procs.sorted { $0.memory > $1.memory }.prefix(5))
            }
        }
        if Date().timeIntervalSince(lastDevices) > 60 { refreshDevices() }
        if smart == "—" {
            Task.detached(priority: .background) {
                let s = Self.smartStatus()
                await MainActor.run { SystemMonitor.shared.smart = s }
            }
        }
    }

    /// Bluetooth devices, drives and their Trash bins (one `system_profiler` call): at most once a minute.
    func refreshDevices() {
        lastDevices = Date()
        Task.detached(priority: .utility) {
            let devs = Self.connectedDevices()
            let bat = Self.batteryInfo()
            var trashes: [String: Int64] = [:]
            for d in devs where d.kind == "drive" {
                if let u = d.url { trashes[d.name] = FS.allocatedSize(u.appendingPathComponent(".Trashes/\(getuid())")) }
            }
            let t = trashes
            let profile = HealthChecks.readProfileProblem()
            await MainActor.run {
                let m = SystemMonitor.shared
                m.devices = devs
                m.battery = bat
                m.driveTrash = t
                m.profileProblem = profile
                m.checkAlerts()
            }
        }
    }

    /// Measures the Trash once (at launch and when `TrashWatcher` sees it change), never on a timer.
    func refreshTrash() {
        Task.detached(priority: .utility) {
            let size = TrashBins.userTrashSize
            await MainActor.run { SystemMonitor.shared.trashSize = size; SystemMonitor.shared.checkAlerts() }
        }
    }

    /// Évalue les règles d'alerte (`Alerts.evaluate`) sur l'état mesuré ; chaque alerte part dans son canal (macOS ou bulle).
    func checkAlerts() {
        var input = AlertInput(diskFree: diskFree, diskTotal: diskTotal, pressure: pressure, swapUsed: swapUsed, trashSize: trashSize, driveTrash: driveTrash)
        input.profileProblem = profileProblem
        Notifier.deliver(Alerts.evaluate(input))
    }

    /// Relevé du profil (préférences Adobe), mis à jour avec les disques : quelques lectures de fichiers, jamais en boucle.
    private var profileProblem: String?

    // MARK: CPU

    private func sampleCPU() -> Double {
        var n: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &count) == KERN_SUCCESS, let info else { return cpu }
        var ticks = [UInt64](repeating: 0, count: 4)
        for i in 0..<Int(n) {
            let base = Int(CPU_STATE_MAX) * i
            ticks[0] += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            ticks[1] += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            ticks[2] += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            ticks[3] += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
        defer { prevTicks = ticks }
        guard let p = prevTicks else { return 0 }
        let d = (0..<4).map { Double(ticks[$0] &- p[$0]) }
        let total = d.reduce(0, +)
        return total > 0 ? (d[0] + d[1] + d[3]) / total * 100 : 0
    }

    // MARK: Memory

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return }
        let page = Int64(vm_kernel_page_size)
        memApp = (Int64(stats.internal_page_count) - Int64(stats.purgeable_count)) * page
        memWired = Int64(stats.wire_count) * page
        memCompressed = Int64(stats.compressor_page_count) * page
        memCache = (Int64(stats.external_page_count) + Int64(stats.purgeable_count)) * page
        memUsed = memApp + memWired + memCompressed
        pressure = Self.memoryPressure()
        swapUsed = Self.swapBytes()
        swapPeak = max(swapPeak, swapUsed)
    }

    /// 1 normal, 2 warning, 4 critical.
    nonisolated static func memoryPressure() -> Int {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? Int(level) : 1
    }

    nonisolated static func swapBytes() -> Int64 {
        var swap = xsw_usage()
        var ss = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &swap, &ss, nil, 0) == 0 ? Int64(swap.xsu_used) : 0
    }

    // MARK: Network

    private func sampleNet() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }
        var inDelta: UInt64 = 0, outDelta: UInt64 = 0
        var current: [String: (UInt32, UInt32)] = [:]
        var up = false
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard !name.hasPrefix("lo"), !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            current[name] = (d.ifi_ibytes, d.ifi_obytes)
            if (Int32(ifa.pointee.ifa_flags) & IFF_RUNNING) != 0 && name.hasPrefix("en") && d.ifi_ibytes > 0 { up = true }
            if let prev = prevNet[name] {
                inDelta += UInt64(d.ifi_ibytes &- prev.0)
                outDelta += UInt64(d.ifi_obytes &- prev.1)
            }
        }
        let dt = max(0.5, Date().timeIntervalSince(prevNetDate))
        if !prevNet.isEmpty {
            netIn = Double(inDelta) / dt
            netOut = Double(outDelta) / dt
            netHistory = Array((netHistory + [netIn]).suffix(40))
        }
        prevNet = current
        prevNetDate = Date()
        connected = up
    }

    func runSpeedTest() {
        speedTesting = true
        speedTest = nil
        Task.detached {
            let r = Shell.run("/usr/bin/networkQuality", ["-s", "-c"], timeout: 90)
            var text = "Test impossible (pas de connexion ?)"
            if let d = r.out.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let dl = (j["dl_throughput"] as? Double ?? 0) / 1_000_000
                let ul = (j["ul_throughput"] as? Double ?? 0) / 1_000_000
                text = "↓ \(Fmt.number(dl)) Mb/s   ↑ \(Fmt.number(ul)) Mb/s"
            }
            let result = text
            await MainActor.run { SystemMonitor.shared.speedTest = result; SystemMonitor.shared.speedTesting = false }
        }
    }

    // MARK: Static samplers

    /// À la minute près (affichage « 3 h 12 min ») : une valeur identique ne redessine rien (Observation).
    nonisolated static func bootUptimeMinute() -> TimeInterval { (bootUptime() / 60).rounded(.down) * 60 }

    nonisolated static func bootUptime() -> TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - Double(tv.tv_sec)
    }

    nonisolated static func disk() -> (Int64, Int64, Int64) {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return (Int64(v?.volumeTotalCapacity ?? 0), v?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v?.volumeAvailableCapacity ?? 0))
    }

    nonisolated static func smartStatus() -> String {
        let out = Shell.run("/usr/sbin/diskutil", ["info", "disk0"]).out
        for l in out.components(separatedBy: "\n") where l.contains("SMART Status") {
            return l.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "—"
        }
        return "Non disponible"
    }

    nonisolated static func batteryInfo() -> BatteryInfo? {
        guard Machine.hasBattery else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }
        let raw = d["AppleRawMaxCapacity"] as? Int ?? 0
        let design = d["DesignCapacity"] as? Int ?? 0
        let tl = d["TimeRemaining"] as? Int ?? 65535
        return BatteryInfo(percent: d["CurrentCapacity"] as? Int ?? 0,
                           charging: d["IsCharging"] as? Bool ?? false,
                           pluggedIn: d["ExternalConnected"] as? Bool ?? false,
                           minutesLeft: (tl > 0 && tl < 6000) ? tl : nil,
                           cycles: d["CycleCount"] as? Int ?? 0,
                           health: design > 0 ? min(100, raw * 100 / design) : 100,
                           temperature: Double(d["Temperature"] as? Int ?? 0) / 100)
    }

    nonisolated static func connectedDevices() -> [DeviceInfo] {
        var out: [DeviceInfo] = []
        let r = Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 20)
        if let d = r.out.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let arr = j["SPBluetoothDataType"] as? [[String: Any]] {
            for ctrl in arr {
                for entry in ctrl["device_connected"] as? [[String: Any]] ?? [] {
                    for (name, v) in entry {
                        let info = v as? [String: Any] ?? [:]
                        let levels = ["device_batteryLevelMain", "device_batteryLevel", "device_batteryLevelLeft", "device_batteryLevelRight", "device_batteryLevelCase"]
                            .compactMap { (info[$0] as? String)?.replacingOccurrences(of: "%", with: "") }.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                        out.append(DeviceInfo(name: name, kind: "bluetooth", detail: info["device_minorType"] as? String ?? "Bluetooth", battery: levels.min(), url: nil))
                    }
                }
            }
        }
        out += mountedDrives()
        return out
    }

    /// Mounted volumes under /Volumes (no Bluetooth call, cheap).
    nonisolated static func mountedDrives() -> [DeviceInfo] {
        var out: [DeviceInfo] = []
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey]
        for v in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            guard let rv = try? v.resourceValues(forKeys: Set(keys)), rv.volumeIsRootFileSystem != true, v.path.hasPrefix("/Volumes/") else { continue }
            let free = Int64(rv.volumeAvailableCapacity ?? 0), total = Int64(rv.volumeTotalCapacity ?? 0)
            out.append(DeviceInfo(name: rv.volumeName ?? v.lastPathComponent, kind: "drive",
                                  detail: "\(Fmt.bytes(free)) libres sur \(Fmt.bytes(total))" + (rv.volumeIsInternal == true ? "" : " · externe"),
                                  battery: nil, url: v, free: free, total: total,
                                  external: rv.volumeIsInternal != true, readOnly: rv.volumeIsReadOnly == true))
        }
        return out
    }
}
