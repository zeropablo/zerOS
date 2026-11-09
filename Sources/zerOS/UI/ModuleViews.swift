import SwiftUI
import AppKit

// MARK: - Shared sessions

@MainActor
enum AppSessions {
    static var cleanup: ScanSession {
        Sessions.shared.get("cleanup", title: "Nettoyage", configure: { $0.emptyMessage = "Aucun fichier à nettoyer" }) { rep in
            if DemoPublic.on { try? await Task.sleep(nanoseconds: 1_500_000_000); return DemoPublic.cleanup() }
            var g = await Junk.scanAll(rep)
            g += CacheScan.scan(rep)
            rep("Pièces jointes Mail…"); g.append(MailJunk.scan())
            rep("Encombrement des apps d'IA…"); g += AIClutter.scan()
            return g
        }
    }

    static var leftovers: ScanSession {
        Sessions.shared.get("leftovers", title: "Restes d'apps", configure: { $0.primaryTitle = "Supprimer"; $0.emptyMessage = "Aucun reste d'app" }) { await AppCatalog.leftovers($0) }
    }

    static var installers: ScanSession {
        Sessions.shared.get("installers", title: "Installateurs", configure: { $0.primaryTitle = "Mettre à la Corbeille"; $0.emptyMessage = "Aucun fichier d'installation" }) { await AppCatalog.installers($0) }
    }

    static var large: ScanSession {
        Sessions.shared.get("large", title: "Mon désordre", configure: { $0.primaryTitle = "Mettre à la Corbeille"; $0.emptyMessage = "Aucun gros fichier ni fichier ancien" }) { await Clutter.largeOld($0) }
    }

    static var dupes: ScanSession {
        Sessions.shared.get("dupes", title: "Mon désordre", configure: { $0.primaryTitle = "Mettre à la Corbeille"; $0.emptyMessage = "Aucun doublon" }) { await Clutter.duplicates($0) }
    }

    static var similar: ScanSession {
        Sessions.shared.get("similar", title: "Mon désordre", configure: { $0.primaryTitle = "Mettre à la Corbeille"; $0.emptyMessage = "Aucune photo similaire" }) { await Clutter.similarImages($0) }
    }

    static var downloads: ScanSession {
        Sessions.shared.get("downloads", title: "Mon désordre", configure: { $0.primaryTitle = "Mettre à la Corbeille"; $0.emptyMessage = "Aucun fichier dans Téléchargements" }) { await Clutter.downloads($0) }
    }

    static var cloud: ScanSession {
        Sessions.shared.get("cloud", title: "Nettoyage du cloud", configure: {
            $0.primaryTitle = "Libérer l'espace"
            $0.secondary = ("Supprimer partout", .trash)
            $0.emptyMessage = "Aucun fichier cloud ne prend de place sur ce Mac"
        }) { await CloudCleanup.scan($0) }
    }
}

// MARK: - Cleanup

struct CleanupView: View {
    @ObservedObject var session = AppSessions.cleanup
    var body: some View {
        VStack(spacing: 0) {
            TrashPanel().padding([.horizontal, .top], Space.gap)
            SessionPage(module: .cleanup, session: session, heroTitle: "Faites de la place",
                        heroText: Module.cleanup.tagline) { FDABanner() }
        }
        .onAppear { if let g = Router.shared.tabs[.cleanup], g != "trash" { session.focusedGroup = g } }
    }
}

// MARK: - My Clutter

struct ClutterView: View {
    let router = Router.shared
    var body: some View {
        let tab = router.tab(.clutter, default: "large")
        Group {
            switch tab.wrappedValue {
            case "dupes":
                SessionPage(module: .clutter, session: AppSessions.dupes, heroTitle: "Trouvez les doublons",
                            heroText: "Les fichiers identiques rangés à plusieurs endroits. Une copie est toujours gardée.", scanLabel: "Chercher")
            case "similar":
                SessionPage(module: .clutter, session: AppSessions.similar, heroTitle: "Photos qui se ressemblent",
                            heroText: "Rafales, captures en double, retouches : images comparées, la meilleure de chaque série est gardée.", scanLabel: "Chercher")
            case "downloads":
                SessionPage(module: .clutter, session: AppSessions.downloads, heroTitle: "Triez vos Téléchargements",
                            heroText: "Tout ce qui s'entasse dans Téléchargements, classé par ancienneté.")
            default:
                SessionPage(module: .clutter, session: AppSessions.large, heroTitle: "Gros fichiers oubliés",
                            heroText: "Les fichiers qui prennent le plus de place et ceux que vous n'avez pas ouverts depuis plus d'un an.")
            }
        }
        .moduleTabs([("large", "Gros & anciens"), ("dupes", "Doublons"), ("similar", "Photos similaires"), ("downloads", "Téléchargements")], selection: tab)
    }
}

// MARK: - Cloud

struct CloudView: View {
    @ObservedObject var session = AppSessions.cloud
    var body: some View {
        SessionPage(module: .cloud, session: session, heroTitle: "Allégez vos clouds",
                    heroText: Module.cloud.tagline) {
            let p = CloudCleanup.providers()
            if !p.isEmpty {
                HStack(spacing: 8) {
                    ForEach(p) { x in
                        Label(x.name, systemImage: x.symbol).font(Typo.detail)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.fill.tertiary, in: Capsule())
                    }
                }
            }
        }
    }
}

// MARK: - Vider la Corbeille (action séparée)

/// « Vider la Corbeille » : à part du nettoyage (jamais coché, jamais dans « Nettoyer »), une ligne par corbeille de l'utilisateur
/// (la sienne, celles des disques externes), confirmation avec nombre, taille, part mise par zerOS depuis 24 h, mention « irréversible ».
struct TrashPanel: View {
    @Local private var bins: [TrashBins.Bin] = []
    @Local private var asking: TrashBins.Bin?
    @Local private var working = false
    @Local private var result: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(bins) { b in
                    HStack(spacing: Space.gap) {
                        Image(systemName: b.url.path.hasPrefix("/Volumes/") ? "externaldrive" : "trash").foregroundStyle(.secondary).frame(width: 20)
                        Text(b.title)
                        Text(b.readable ? "\(Fmt.count(b.count, "élément")) · \(Fmt.bytes(b.size))" : "Illisible sans l'accès complet au disque")
                            .font(Typo.detail).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Button("Vider la Corbeille…") { asking = b }
                            .disabled(working || !b.readable || b.count == 0)
                    }
                }
                if let result { Text(result).font(Typo.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(4)
        }
        .task { await reload() }
        .alert("Vider \(asking?.title ?? "la Corbeille") ?", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            Button("Annuler", role: .cancel) { asking = nil }
            Button("Vider", role: .destructive) { if let b = asking { empty(b) }; asking = nil }
        } message: {
            Text(asking.map(TrashBins.confirmation) ?? "")
        }
    }

    func reload() async {
        let b = await Task.detached(priority: .utility) { TrashBins.bins() }.value
        if b != bins { bins = b }
    }

    func empty(_ b: TrashBins.Bin) {
        working = true
        Task {
            let r = await Task.detached(priority: .userInitiated) { TrashBins.empty(b.url) }.value
            ActivityStore.shared.log(module: "Corbeille", text: "\(b.title) vidée : \(Fmt.count(r.removed, "élément supprimé", "éléments supprimés"))", bytes: r.freed)
            result = "\(b.title) : \(Fmt.count(r.removed, "élément supprimé", "éléments supprimés")), \(Fmt.bytes(r.freed)) libérés"
                + (r.left.isEmpty ? "." : ". Laissés en place : " + r.left.prefix(5).joined(separator: " ; ") + (r.left.count > 5 ? " ; …" : ""))
            working = false
            SystemMonitor.shared.refreshTrash()
            await reload()
        }
    }
}
