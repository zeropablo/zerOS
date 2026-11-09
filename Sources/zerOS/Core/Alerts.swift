import Foundation

/// Où une alerte est affichée (SPEC.md, Notifications) : notification macOS pour le critique seulement, tout le reste en bulle
/// sous l'icône de la barre des menus (elle disparaît seule). Le tableau `Alerts.rules` est la seule source : l'autotest le relit.
enum AlertChannel: String, Sendable { case macOS, bubble }

struct Alert: Sendable, Equatable {
    var id: String
    var channel: AlertChannel
    var title: String
    var body: String
    var link: Module? = nil
}

struct AlertRule: Sendable {
    let id: String
    let channel: AlertChannel
    /// Délai minimal entre deux affichages ; 0 = à chaque événement.
    let every: TimeInterval
    let trigger: String
}

/// État mesuré qui déclenche les règles à seuil (tout est passé en paramètre : les tests simulent chaque cas).
struct AlertInput: Sendable {
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var pressure = 1
    var swapUsed: Int64 = 0
    var trashSize: Int64 = 0
    var driveTrash: [String: Int64] = [:]
    /// Texte de l'alerte de profil (cache Adobe vers un volume absent), nil si rien à signaler.
    var profileProblem: String?
}

enum Alerts {
    static let day: TimeInterval = 86400

    static let rules: [AlertRule] = common

    private static let common: [AlertRule] = [
        AlertRule(id: "disk", channel: .macOS, every: day, trigger: "disque interne sous 10 % libre"),
        AlertRule(id: "lowmem", channel: .bubble, every: 3600, trigger: "pression mémoire critique"),
        AlertRule(id: "trash", channel: .bubble, every: day, trigger: "Corbeille au-delà de 5 Go"),
        AlertRule(id: "drivetrash", channel: .bubble, every: day, trigger: "corbeille d'un disque externe au-delà de 1 Go"),
        AlertRule(id: "app-trash", channel: .bubble, every: 0, trigger: "app jetée qui laisse des restes"),
        AlertRule(id: "profile", channel: .bubble, every: day, trigger: "cache Adobe vers un volume absent"),
    ]

    static func rule(_ id: String) -> AlertRule? {
        rules.first { $0.id == id || id.hasPrefix($0.id + ".") }
    }

    static let trashBytes: Int64 = 5_000_000_000
    static let driveTrashBytes: Int64 = 1_000_000_000

    // MARK: Règles à seuil

    static func evaluate(_ i: AlertInput, now: Date = Date()) -> [Alert] {
        var out: [Alert] = []
        func add(_ id: String, _ title: String, _ body: String, _ link: Module?, key: String? = nil) {
            out.append(Alert(id: key ?? id, channel: rule(id)!.channel, title: title, body: body, link: link))
        }
        if i.diskTotal > 0, Double(i.diskFree) / Double(i.diskTotal) < Thresholds.diskRedFree {
            add("disk", "Disque presque plein", "\(Fmt.bytes(i.diskFree)) libres sur \(Fmt.bytes(i.diskTotal)).", .cleanup)
        }
        if i.pressure >= Thresholds.memoryNotifyPressure {
            add("lowmem", "Mémoire presque pleine", "Pression mémoire critique. Échange : \(Fmt.bytes(i.swapUsed)).", .performance)
        }
        if i.trashSize > trashBytes {
            add("trash", "Corbeille bien remplie", "\(Fmt.bytes(i.trashSize)) dans la Corbeille.", .cleanup)
        }
        for (name, s) in i.driveTrash.sorted(by: { $0.key < $1.key }) where s > driveTrashBytes {
            add("drivetrash", "Corbeille pleine sur « \(name) »", "\(Fmt.bytes(s)) de fichiers jetés sur ce disque.", .cleanup, key: "drivetrash." + name)
        }
        if let p = i.profileProblem {
            add("profile", "Profil de machine", p, .performance)
        }
        return out
    }


    static func appInTrash(name: String, files: Int, bytes: Int64) -> Alert {
        Alert(id: "app-trash", channel: rule("app-trash")!.channel, title: "\(name) dans la Corbeille",
              body: "Restes : \(Fmt.count(files, "fichier")), \(Fmt.bytes(bytes)). Apps > Restes.", link: .applications)
    }

    // MARK: Cadence

    /// Garde ceux dont le délai est écoulé et note l'heure dans `last`. `every` = 0 : toujours.
    static func due(_ alerts: [Alert], now: Date, last: inout [String: Date]) -> [Alert] {
        alerts.filter { a in
            let every = rule(a.id)?.every ?? 0
            if every > 0, let t = last[a.id], now.timeIntervalSince(t) < every { return false }
            last[a.id] = now
            return true
        }
    }
}

extension Notifier {
    /// Cadence conservée entre deux lancements.
    private static func loadLast() -> [String: Date] {
        (UserDefaults.standard.dictionary(forKey: "alerts.last") as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// Affiche les alertes dont le délai est écoulé, par leur canal.
    @MainActor
    static func deliver(_ all: [Alert], now: Date = Date()) {
        let alerts = all
        guard !alerts.isEmpty else { return }
        var last = loadLast()
        let go = Alerts.due(alerts, now: now, last: &last)
        UserDefaults.standard.set(last.mapValues(\.timeIntervalSince1970), forKey: "alerts.last")
        for a in go { show(a) }
    }

    @MainActor
    static func show(_ a: Alert) {
        ActivityStore.shared.record(a.title, a.body, link: a.link)
        switch a.channel {
        case .macOS: post(a.title, a.body)
        case .bubble: MenuBubble.shared.show(a)
        }
    }
}
