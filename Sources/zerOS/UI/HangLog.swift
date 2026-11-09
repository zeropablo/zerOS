import AppKit
import Darwin
import Synchronization

/// Détecteur de blocage (`--hang-log`, jamais en fonctionnement normal) : un fil de surveillance regarde depuis combien de temps le tour
/// de boucle en cours du fil principal dure (deux observateurs de la boucle : chaque étape d'un tour — minuteries, sources, réveil — et la
/// fin du tour, placée après la validation Core Animation où SwiftUI fait sa mise en page). Au-delà de 50 ms, il relève la pile du fil principal toutes les 10 ms (fil suspendu
/// le temps de lire ses cadres, aucune allocation pendant la suspension). À la fin du blocage, une ligne `HANG` est ajoutée à
/// `FS.support/hangs.txt` : instant, durée, écran, fonction de zerOS la plus haute dans la pile (la plus fréquente des échantillons), puis
/// la pile de l'échantillon du milieu. Fenêtre fermée, le fil ne se réveille que deux fois par seconde.
final class HangLog: @unchecked Sendable {
    static let shared = HangLog()
    static let threshold: UInt64 = 50_000_000

    /// Début du tour de boucle en cours (ns, horloge de `CACurrentMediaTime`), 0 = fil principal en attente.
    private let busySince = Atomic<UInt64>(0)
    private let idleAt = Atomic<UInt64>(0)
    private let active = Atomic<Bool>(false)
    private var main: thread_t = 0
    private var liveTask: Task<Void, Never>?
    private let maxFrames = 96
    private let buffer: UnsafeMutablePointer<UInt>
    private let url = FS.support.appendingPathComponent("hangs.txt")

    private init() { buffer = .allocate(capacity: 96) }

    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    @MainActor func start() {
        guard main == 0 else { return }
        main = mach_thread_self()
        try? FileManager.default.removeItem(at: url)
        try? "# blocages du fil principal > 50 ms : HANG t(s) durée(ms) écran fonction (échantillons)\n".write(to: url, atomically: true, encoding: .utf8)
        let begin: CFOptionFlags = CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.beforeTimers.rawValue
            | CFRunLoopActivity.beforeSources.rawValue | CFRunLoopActivity.afterWaiting.rawValue
        let o1 = CFRunLoopObserverCreateWithHandler(nil, begin, true, CFIndex.min) { [self] _, _ in
            busySince.store(Self.now(), ordering: .relaxed)
        }
        let o2 = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, CFIndex.max) { [self] _, _ in
            idleAt.store(Self.now(), ordering: .relaxed); busySince.store(0, ordering: .relaxed)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o1, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), o2, .commonModes)
        liveTask = Task { @MainActor [self] in
            if #available(macOS 26, *) {
                for await live in Observations({ @MainActor in Nav.shared.live }) { active.store(live, ordering: .relaxed) }
            } else {
                for await live in Observed.values({ Nav.shared.live }) { active.store(live, ordering: .relaxed) }
            }
        }
        Thread.detachNewThread { [self] in watch() }
    }

    private func watch() {
        var hangStart: UInt64 = 0
        var samples: [[UInt]] = []
        var lastSample: UInt64 = 0
        while true {
            guard active.load(ordering: .relaxed) else { usleep(500_000); hangStart = 0; samples = []; continue }
            usleep(5_000)
            let b = busySince.load(ordering: .relaxed), t = Self.now()
            if hangStart != 0 && b != hangStart {
                // Fin du blocage : fin de tour notée par l'observateur, ou début du tour suivant.
                let end = b == 0 ? max(idleAt.load(ordering: .relaxed), hangStart) : b
                report(start: hangStart, ms: Double(end - hangStart) / 1e6, samples: samples)
                hangStart = 0; samples = []
            }
            guard b != 0, t > b, t - b > Self.threshold else { continue }
            if hangStart == 0 { hangStart = b; lastSample = 0 }
            if t - lastSample >= 10_000_000, samples.count < 200 {
                let n = sample()
                if n > 0 { samples.append(Array(UnsafeBufferPointer(start: buffer, count: n))) }
                lastSample = t
            }
        }
    }

    /// Pile du fil principal (adresses de retour), relevée en suivant les pointeurs de cadre ; rien n'est alloué pendant la suspension.
    private func sample() -> Int {
        guard thread_suspend(main) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(main) }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(main, ARM_THREAD_STATE64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let mask: UInt = 0x0000_7FFF_FFFF_FFFF
        buffer[0] = UInt(state.__pc) & mask
        buffer[1] = UInt(state.__lr) & mask
        var n = 2
        var fp = UInt(state.__fp)
        var pair: (UInt, UInt) = (0, 0)
        while n < maxFrames, fp != 0, fp % 8 == 0 {
            var got: vm_size_t = 0
            let r = withUnsafeMutablePointer(to: &pair) {
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), 16, vm_address_t(UInt(bitPattern: $0)), &got)
            }
            guard r == KERN_SUCCESS, pair.1 != 0 else { break }
            buffer[n] = pair.1 & mask; n += 1
            guard pair.0 > fp else { break }
            fp = pair.0
        }
        return n
    }

    private func report(start: UInt64, ms: Double, samples: [[UInt]]) {
        let exe = Bundle.main.executablePath ?? ""
        // Adresses de zerOS : noms retrouvés par atos (l'exécutable garde ses symboles) ; les autres par dladdr.
        let base = Self.loadAddress()
        let ours = Set(samples.flatMap { $0 }.filter { Self.image($0) == exe })
        var names: [UInt: String] = [:]
        if !ours.isEmpty, base != 0 {
            let list = Array(ours)
            let r = Shell.run("/usr/bin/atos", ["-o", exe, "-l", String(format: "0x%lx", base)] + list.map { String(format: "0x%lx", $0) })
            for (a, l) in zip(list, r.out.components(separatedBy: "\n")) { names[a] = Self.short(l) }
        }
        func name(_ a: UInt) -> String {
            if let n = names[a] { return n }
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: a), &info) != 0 else { return String(format: "0x%lx", a) }
            let lib = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
            let sym = info.dli_sname.map { Self.demangle(String(cString: $0)) } ?? "?"
            return "\(lib) · \(sym)"
        }
        // Fonction : la plus haute de zerOS dans chaque échantillon (hors point d'entrée), sinon la plus haute de SwiftUI / AppKit /
        // Core Animation, préfixée « système » ; la plus fréquente des échantillons.
        let entry = ["main ", "ZerOSApp.$main", "static ZerOSApp.main"]
        let frameworks = ["SwiftUI ·", "SwiftUICore ·", "AppKit ·", "QuartzCore ·"]
        var counts: [String: Int] = [:]
        for s in samples {
            let mine = s.first { ours.contains($0) && !entry.contains(where: name($0).hasPrefix) }
            let label = mine.map(name) ?? s.lazy.map(name).first { n in frameworks.contains { n.hasPrefix($0) } }.map { "système · " + $0 }
            if let label { counts[label, default: 0] += 1 }
        }
        let top = counts.max { $0.value < $1.value }
        let mid = samples.isEmpty ? [] : samples[samples.count / 2]
        let stack = mid.prefix(40).enumerated().map { "    \($0.offset) \(name($0.element))" }.joined(separator: "\n")
        let t = Double(start) / 1e9
        DispatchQueue.main.async { [self] in
            let screen = MainActor.assumeIsolated { () -> String in
                let nav = Nav.shared, r = Router.shared
                let sub = r.sub[nav.section]?.rawValue ?? (nav.section == .apps ? r.tabs[.applications] ?? "uninstall" : "-")
                return "\(nav.section.rawValue)/\(sub)"
            }
            let fn = top.map { "\($0.key) (\($0.value)/\(samples.count))" } ?? "hors de zerOS (\(samples.count) échantillons)"
            let text = String(format: "HANG %.3f %.0f %@ %@\n", t, ms, screen, fn) + (stack.isEmpty ? "" : stack + "\n")
            DispatchQueue.global(qos: .utility).async { [self] in
                if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
            }
        }
    }

    private static func image(_ a: UInt) -> String? {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: a), &info) != 0, let f = info.dli_fname else { return nil }
        return String(cString: f)
    }

    private static func loadAddress() -> UInt {
        for i in 0..<_dyld_image_count() where _dyld_get_image_name(i).map({ String(cString: $0) }) == Bundle.main.executablePath {
            return UInt(bitPattern: _dyld_get_image_header(i))
        }
        return 0
    }

    /// « closure #1 in StorageView.body.getter (in zerOS) (StorageView.swift:412) » → « closure #1 in StorageView.body.getter (StorageView.swift:412) ».
    private static func short(_ s: String) -> String { s.replacingOccurrences(of: " (in zerOS)", with: "") }

    private static func demangle(_ s: String) -> String {
        typealias Fn = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
        guard s.hasPrefix("$s") || s.hasPrefix("_$s"), let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return s }
        let fn = unsafeBitCast(f, to: Fn.self)
        guard let out = s.withCString({ fn($0, strlen($0), nil, nil, 0) }) else { return s }
        defer { free(out) }
        return String(cString: out)
    }
}
