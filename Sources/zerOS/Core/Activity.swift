import Foundation
import SwiftUI
import UserNotifications
import FoundationModels

struct ActivityEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var module: String
    var text: String
    var bytes: Int64
}

struct AppNotice: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var title: String
    var body: String
    var read = false
    var link: String? = nil   // Module raw value
}

@MainActor
final class ActivityStore: ObservableObject {
    static let shared = ActivityStore()

    @Published var entries: [ActivityEntry] = []
    @Published var notices: [AppNotice] = []
    @Published var lastRun: [String: Date] = [:]

    private struct Saved: Codable {
        var entries: [ActivityEntry]
        var notices: [AppNotice]
        var lastRun: [String: Date]
    }

    private let file: URL = {
        let dir = FS.support
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("activity.json")
    }()

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            entries = s.entries; notices = s.notices; lastRun = s.lastRun
        }
    }

    func save() {
        let s = Saved(entries: Array(entries.prefix(800)), notices: Array(notices.prefix(200)), lastRun: lastRun)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: file, options: .atomic) }
    }

    var totalFreed: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    var unread: Int { notices.filter { !$0.read }.count }

    func freed(since: Date) -> Int64 { entries.filter { $0.date >= since }.reduce(0) { $0 + $1.bytes } }

    /// Rough estimate: 2 minutes saved per action, plus 1 minute per GB cleaned.
    var minutesSaved: Int { entries.count * 2 + Int(totalFreed / 1_000_000_000) }

    func log(module: String, text: String, bytes: Int64) {
        entries.insert(ActivityEntry(date: Date(), module: module, text: text, bytes: bytes), at: 0)
        markRun(module)
        save()
    }

    func markRun(_ key: String) { lastRun[key] = Date(); save() }

    /// Garde l'alerte dans la liste des notifications (cloche) ; l'affichage est décidé par `Notifier.deliver`.
    func record(_ title: String, _ body: String, link: Module? = nil) {
        notices.insert(AppNotice(date: Date(), title: title, body: body, link: link?.rawValue), at: 0)
        save()
    }

    func markAllRead() {
        notices = notices.map { var n = $0; n.read = true; return n }
        save()
    }
}

enum Notifier {
    static func setup() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }


    static func post(_ title: String, _ body: String) {
        guard UserDefaults.standard.object(forKey: "notificationsOn") as? Bool ?? true else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

// MARK: - Smart Insights (Apple Intelligence, on-device)

enum SmartInsights {
    /// Apple Intelligence sur l'appareil : macOS 26 et plus seulement.
    static var isAvailable: Bool {
        guard #available(macOS 26, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var unavailableReason: String {
        guard #available(macOS 26, *) else { return "Les explications demandent macOS 26 ou plus récent." }
        switch SystemLanguageModel.default.availability {
        case .available: return ""
        case .unavailable(let r):
            switch r {
            case .appleIntelligenceNotEnabled: return "Activez Apple Intelligence dans Réglages Système pour obtenir des explications."
            case .deviceNotEligible: return "Ce Mac ne prend pas en charge Apple Intelligence."
            case .modelNotReady: return "Le modèle Apple Intelligence est encore en cours de téléchargement."
            @unknown default: return "Apple Intelligence n'est pas disponible."
            }
        }
    }

    static func explain(title: String, path: String?, context: String) async -> String {
        guard #available(macOS 26, *), isAvailable else { return unavailableReason }
        do {
            let session = LanguageModelSession(instructions: """
            Tu es un expert Mac qui parle à quelqu'un qui n'est pas informaticien. \
            Réponds en français simple, sans jargon, en 3 phrases maximum : \
            ce que c'est, à quoi ça sert, et si on peut le supprimer sans risque.
            """)
            let prompt = "Élément : \(title)\nEmplacement : \(path ?? "inconnu")\nCatégorie : \(context)"
            let r = try await session.respond(to: prompt)
            return r.content
        } catch {
            return "Explication indisponible pour le moment."
        }
    }
}
