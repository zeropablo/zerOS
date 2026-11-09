import Foundation

/// « Aujourd'hui » : des états calculés à partir de données réelles, puis au plus trois actions proposées par des règles.
/// Aucun texte ici n'est une phrase personnifiée : des chiffres, un niveau, une action.

enum Level: Int, Comparable, Sendable {
    case green, orange, red
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    var label: String { ["Bon", "À surveiller", "Critique"][rawValue] }
}

/// Tous les seuils des états d'Aujourd'hui sont ici, et seulement ici.
enum Thresholds {
    /// Disque interne : part d'espace libre.
    static let diskOrangeFree = 0.20
    static let diskRedFree = 0.10
    /// Mémoire : fichier d'échange en part de la mémoire vive. La pression système (2 = élevée, 4 = critique) compte aussi.
    static let swapOrangeRatio = 0.10
    static let swapRedRatio = 0.25
    /// Disques externes : part d'espace libre du volume le plus rempli.
    static let externalOrangeFree = 0.15
    static let externalRedFree = 0.05
    /// Notification « Mémoire presque pleine » : pression système à partir de ce niveau (4 = critique). À ajuster après tests réels.
    static let memoryNotifyPressure = 4
    /// Règles d'actions.
    static let trashActionBytes: Int64 = 2_000_000_000
    static let cachesActionBytes: Int64 = 200_000_000
    /// « Déplacer <app> » : données d'une app installée sur le disque interne, quand celui-ci n'est pas au vert.
    static let moveActionBytes: Int64 = 1_000_000_000
    static let maxActions = 3
}


struct TodaySnapshot: Sendable {
    var diskFree: Int64
    var diskTotal: Int64
    var pressure: Int
    var swapUsed: Int64
    var memTotal: Int64
    var externals: [DeviceInfo]
    var trashSize: Int64
    /// Caches régénérables déjà mesurés par une analyse de Nettoyage (nil = pas encore analysé).
    var reclaimable: Int64? = nil
    var pendingUpdates: Int? = nil
    /// Données d'apps installées déplaçables vers le disque de données (catalogue `Relocate`, mesuré sur le disque interne).
    var movable: [(name: String, bytes: Int64)] = []
    var dataVolumePlugged = false
    var now = Date()

    /// Lectures réelles, sans le fil principal (utilisable par l'autotest).
    static func live() -> TodaySnapshot {
        let d = SystemMonitor.disk()
        var s = TodaySnapshot(diskFree: d.1, diskTotal: d.0,
                             pressure: SystemMonitor.memoryPressure(), swapUsed: SystemMonitor.swapBytes(),
                             memTotal: Int64(ProcessInfo.processInfo.physicalMemory),
                             externals: SystemMonitor.mountedDrives().filter { $0.external && !$0.readOnly && $0.total > 0 },
                             trashSize: TrashBins.userTrashSize,
                             movable: Relocate.measure(context: .live()).filter { !$0.installed.isEmpty && $0.size > 0 && $0.entry.id != "photos" && $0.entry.id != "adobe-cache" }.map { ($0.entry.short, $0.size) },
                             dataVolumePlugged: Config.relocateTarget != nil)
        return s
    }
}

struct TodayState: Identifiable, Sendable {
    enum Kind: String, Sendable { case disk, memory, externals }
    var id: String { kind.rawValue }
    let kind: Kind
    let title: String
    let value: String
    let detail: String
    let level: Level
    /// Part pleine de la jauge (0…1), si elle a un sens.
    var gauge: Double? = nil
    let target: Module
}

struct TodayAction: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let button: String
    let level: Level
    let target: Module
    var tab: String? = nil
    /// Lance l'analyse de Nettoyage avant d'y aller (aucune suppression : les résultats sont toujours montrés).
    var startsCleanupScan = false
}

enum TodayEngine {
    static func states(_ s: TodaySnapshot) -> [TodayState] {
        [disk(s), memory(s), externals(s)]
    }

    static func disk(_ s: TodaySnapshot) -> TodayState {
        let freeRatio = s.diskTotal > 0 ? Double(s.diskFree) / Double(s.diskTotal) : 1
        let level: Level = freeRatio < Thresholds.diskRedFree ? .red : (freeRatio < Thresholds.diskOrangeFree ? .orange : .green)
        return TodayState(kind: .disk, title: "Disque interne", value: "\(Fmt.bytes(s.diskFree)) libres",
                          detail: "sur \(Fmt.bytes(s.diskTotal)) · \(Fmt.percent(freeRatio * 100)) libre", level: level,
                          gauge: s.diskTotal > 0 ? 1 - freeRatio : nil, target: .cleanup)
    }


    static func memory(_ s: TodaySnapshot) -> TodayState {
        let swapRatio = s.memTotal > 0 ? Double(s.swapUsed) / Double(s.memTotal) : 0
        let swapLevel: Level = swapRatio >= Thresholds.swapRedRatio ? .red : (swapRatio >= Thresholds.swapOrangeRatio ? .orange : .green)
        let pressureLevel: Level = s.pressure >= 4 ? .red : (s.pressure >= 2 ? .orange : .green)
        let pressureLabel = s.pressure >= 4 ? "critique" : (s.pressure >= 2 ? "élevée" : "normale")
        return TodayState(kind: .memory, title: "Mémoire", value: "pression \(pressureLabel)",
                          detail: "échange : \(Fmt.mem(s.swapUsed)) sur \(Fmt.mem(s.memTotal))", level: max(swapLevel, pressureLevel), target: .performance)
    }

    static func externals(_ s: TodaySnapshot) -> TodayState {
        guard !s.externals.isEmpty else {
            return TodayState(kind: .externals, title: "Disques externes", value: "Aucun monté", detail: "Branchez un disque pour le suivre ici", level: .green, target: .cleanup)
        }
        func ratio(_ d: DeviceInfo) -> Double { Double(d.free) / Double(max(1, d.total)) }
        let worst = s.externals.min { ratio($0) < ratio($1) }!
        let r = ratio(worst)
        let level: Level = r < Thresholds.externalRedFree ? .red : (r < Thresholds.externalOrangeFree ? .orange : .green)
        let list = s.externals.map { "\($0.name) : \(Fmt.bytes($0.free)) libres" }.joined(separator: " · ")
        return TodayState(kind: .externals, title: "Disques externes", value: Fmt.count(s.externals.count, "monté"), detail: list, level: level, target: .cleanup)
    }

    /// Règles, par priorité décroissante ; seules celles dont la condition est vraie produisent une action. Au plus `maxActions`,
    /// les états les plus graves d'abord.
    static func actions(_ s: TodaySnapshot) -> [TodayAction] {
        let st = Dictionary(uniqueKeysWithValues: states(s).map { ($0.kind, $0) })
        var out: [TodayAction] = []

        if let r = s.reclaimable, r >= Thresholds.cachesActionBytes {
            out.append(TodayAction(id: "caches", title: "Supprimer \(Fmt.bytes(r)) de caches régénérables", detail: "Les résultats sont montrés avant toute suppression.",
                                   button: "Voir", level: st[.disk]!.level, target: .cleanup))
        } else if st[.disk]!.level != .green && s.reclaimable == nil {
            out.append(TodayAction(id: "scan", title: "Analyser ce qui prend de la place", detail: "Caches, journaux, corbeilles, restes d'apps. Rien n'est supprimé sans votre accord.",
                                   button: "Analyser", level: st[.disk]!.level, target: .cleanup, startsCleanupScan: true))
        }
        if s.trashSize >= Thresholds.trashActionBytes {
            out.append(TodayAction(id: "trash", title: "Vider la corbeille : \(Fmt.bytes(s.trashSize))", detail: "Corbeille de l'utilisateur.",
                                   button: "Voir", level: .orange, target: .cleanup, tab: "trash"))
        }
        // Disque interne pas au vert : la plus grosse app installée dont les données se déplacent (moteur de classification, rien n'est déplacé).
        if st[.disk]!.level != .green, s.dataVolumePlugged, let m = s.movable.max(by: { $0.bytes < $1.bytes }), m.bytes >= Thresholds.moveActionBytes {
            out.append(TodayAction(id: "move", title: "Déplacer \(m.name) : \(Fmt.bytes(m.bytes))",
                                   detail: "Vers « \(Config.relocateTarget?.name ?? "le disque de données") ». Marche à suivre uniquement : zerOS ne déplace rien.", button: "Voir", level: st[.disk]!.level, target: .relocate))
        }
        if st[.memory]!.level != .green {
            out.append(TodayAction(id: "memory", title: "Voir les apps qui consomment la mémoire", detail: st[.memory]!.detail,
                                   button: "Voir", level: st[.memory]!.level, target: .performance, tab: "tasks"))
        }
        if st[.externals]!.level != .green, let worst = s.externals.min(by: { Double($0.free) / Double(max(1, $0.total)) < Double($1.free) / Double(max(1, $1.total)) }) {
            out.append(TodayAction(id: "external", title: "Libérer de l'espace sur « \(worst.name) »", detail: "\(Fmt.bytes(worst.free)) libres",
                                   button: "Voir", level: st[.externals]!.level, target: .spaceLens))
        }
        if let u = s.pendingUpdates, u > 0 {
            out.append(TodayAction(id: "updates", title: Fmt.count(u, "mise à jour d'app disponible", "mises à jour d'apps disponibles"), detail: "",
                                   button: "Voir", level: .orange, target: .applications, tab: "updates"))
        }
        // Stable : les niveaux les plus graves d'abord, l'ordre des règles départage.
        return Array(out.enumerated().sorted { ($0.element.level, $1.offset) > ($1.element.level, $0.offset) }.map(\.element).prefix(Thresholds.maxActions))
    }
}
