import SwiftUI
import AppKit
import Darwin

struct MainView: View {
    /// La coquille ne lit que `Nav` (section, fenêtre vivante, sections de la navigation) : un changement de sous-vue ou d'onglet (`Router`)
    /// ne refait ni la barre latérale, ni le fond, ni la barre d'outils.
    let nav = Nav.shared

    var body: some View {
        // Fenêtre fermée : le contenu est défait (la fenêtre SwiftUI, elle, reste en mémoire) ; il revient à la réouverture.
        Group { if nav.live { ThemeRoot(section: nav.section) { WindowShell() } } else { Color.clear } }
            .background(WindowVisibility())
    }

    @ViewBuilder static func page(_ s: AppSection) -> some View {
        switch s {
        case .today: TodayView()
        case .storage: SubviewPage(section: .storage)
        case .apps: ApplicationsView()
        case .health: PerformanceView()
        case .journal: ActivityView()
        }
    }
}

/// Coquille de la fenêtre (DESIGN.md §6) : rail de navigation au bord gauche, zone de contenu aux coins arrondis à sa droite.
/// Sans paramètre et sans rien observer : un changement de section ne refait ni la barre d'outils ni la pile de navigation,
/// seulement les vues qui lisent la section.
struct WindowShell: View {
    var body: some View {
        ZStack(alignment: .leading) {
            NavigationStack {
                ContentCard()
                    .padding(.leading, Rail.inset).padding(.trailing, Rail.margin).padding(.top, Rail.toolbarHeight).padding(.bottom, Rail.margin)
                    .navigationTitle("zerOS")
                    .toolbar(removing: .title)
                    .modifier(ShellToolbar())
            }
            NavRail()
            SectionTitle()
        }
    }
}

/// Barre d'outils : la cloche seule, à droite. macOS 26 : l'espace flexible l'y garde (sans titre dans la barre) ; une barre écrite
/// avec `if #available` à l'intérieur perdait le verre de la cloche, d'où deux barres entières. macOS 15 : elle y est déjà.
private struct ShellToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.toolbar {
                ToolbarSpacer(.flexible)
                ToolbarItemGroup(placement: .primaryAction) { TopBar() }
            }
        } else {
            content.toolbar { ToolbarItemGroup(placement: .primaryAction) { TopBar() } }
        }
    }
}

/// Zone de contenu : fond flouté de la section, pages, coins arrondis.
struct ContentCard: View {
    let nav = Nav.shared
    var body: some View {
        PageDeck(section: nav.section)
            .background { if ThemePack.shared.hasBackgrounds { ThemeBlurInContent(section: nav.section) } }
            .clipShape(RoundedRectangle(cornerRadius: Radius.content, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.content, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 1).allowsHitTesting(false))
    }
}

/// Titre de la section, posé par zerOS dans la barre de titre (aligné sur le contenu) : le titre de la barre d'outils, lui, obligeait
/// AppKit à refaire la mise en page de toute la barre à chaque changement de section (≈ 18 ms par changement, mesuré 0.9.9).
struct SectionTitle: View {
    let nav = Nav.shared
    var body: some View {
        Text(nav.section.title)
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
            .morph(key: nav.section, .detail)
            .frame(height: Rail.toolbarHeight - 6)
            .padding(.leading, Rail.inset + 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Visibilité d'une page gardée construite (lue par `onShow` et les chargements animés).
@MainActor
final class PageState: ObservableObject {
    @Published var shown = true
    /// Hors d'une page de section (fenêtres annexes, aperçus) : toujours affichée.
    static let always = PageState()
}

/// Une page de section avec l'habillage du thème (ses vues ne reçoivent pas l'environnement de la fenêtre : elles ont leur propre hôte).
/// Chaque page a sa propre teinte de verre, constante.
struct PageRoot: View {
    let section: AppSection
    let state: PageState
    var body: some View {
        MainView.page(section)
            .fullPage()
            .groupBoxStyle(ThemePanelStyle())
            .buttonBorderShape(.capsule)
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds(.disabled)
            .environment(\.themeGlassTint, ThemePack.shared.style(section).glassTint)
            .environment(\.pageState, state)
            .accessibilityRoot()
    }
}

/// Pages des sections, chacune dans sa propre vue hôte AppKit : construites à la première visite (jamais d'avance, MACOS-RULES §6) puis gardées (cachées) tant que la
/// fenêtre est ouverte. Le changement de section est un fondu enchaîné joué par Core Animation (0,45 s) : aucun calcul image par
/// image sur le fil principal, rien à reconstruire au retour dans une section (mesuré 0.9.9 : le fondu fait par SwiftUI recalculait
/// les deux pages à chaque image, 17 à 30 ms par image sur Apps et Journal).
struct PageDeck: NSViewRepresentable {
    let section: AppSection
    func makeNSView(context: Context) -> DeckView { DeckView() }
    func updateNSView(_ v: DeckView, context: Context) { v.show(section) }
}

@MainActor
final class DeckView: NSView {
    private var pages: [AppSection: (host: NSHostingView<PageRoot>, state: PageState)] = [:]
    private var current: AppSection?

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }

    func show(_ s: AppSection) {
        guard s != current else { return }
        let old = current.flatMap { pages[$0] }
        current = s
        old?.state.shown = false
        // Le clavier quitte la page qui s'en va (un champ de recherche caché ne garde pas la saisie).
        if let old, let r = window?.firstResponder as? NSView, r.isDescendant(of: old.host) { window?.makeFirstResponder(nil) }
        // Première page : pas de fondu.
        guard old != nil else { let new = pages[s] ?? make(s, shown: true); new.state.shown = true; fade(new.host, to: 1, duration: 0); Settle.shared.end(); return }
        let token = Settle.shared.begin()
        // La fin du fondu (Core Animation, synchronisé à l'écran) libère les données en attente : aucune minuterie.
        let crossfade = { [weak self] (new: NSHostingView<PageRoot>) in
            guard let self, self.current == s else { return }
            CATransaction.begin()
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { Settle.shared.end(token) } }
            for (k, p) in self.pages where k != s { self.fade(p.host, to: 0, duration: Motion.pageFade) }
            self.fade(new, to: 1, duration: Motion.pageFade)
            CATransaction.commit()
        }
        if let new = pages[s] { new.state.shown = true; crossfade(new.host); return }
        // Page pas encore construite : l'ancienne s'efface d'abord seule, la nouvelle n'est construite qu'à la fin de ce fondu et
        // seulement si elle est toujours demandée. Clics rapides : seule la page où l'on s'arrête est construite, jamais deux à la fois,
        // jamais pendant un fondu ; sa première image est envoyée à l'écran avant que son propre fondu commence.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.current == s, self.pages[s] == nil else { return }
                let new = self.make(s, shown: true)
                new.host.layoutSubtreeIfNeeded()
                DispatchQueue.main.async { MainActor.assumeIsolated { crossfade(new.host) } }
            }
        }
        for (k, p) in pages where k != s { fade(p.host, to: 0, duration: Motion.pageFade) }
        CATransaction.commit()
    }

    /// Opacité du calque animée par Core Animation (dans le serveur de rendu : rien à calculer sur le fil principal pendant le fondu),
    /// repartant de l'opacité affichée si un fondu était en cours.
    private func fade(_ v: NSView, to target: Float, duration: Double) {
        guard let l = v.layer else { return }
        let from = l.presentation()?.opacity ?? l.opacity
        l.removeAnimation(forKey: "fade")
        l.opacity = target
        guard duration > 0 else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from; a.toValue = target; a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        l.add(a, forKey: "fade")
    }

    /// Les pages cachées restent à opacité nulle sans être masquées (`isHidden`) : une vue hôte masquée refait toute sa mise en page en
    /// réapparaissant (≈ 70 ms mesurés). Les clics et les raccourcis clavier (Retour d'un bouton par défaut…) ne vont donc qu'à la page affichée.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let c = current, let h = pages[c]?.host else { return nil }
        return h.hitTest(convert(point, from: superview))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let c = current, let h = pages[c]?.host else { return false }
        return h.performKeyEquivalent(with: event)
    }

    private func make(_ s: AppSection, shown: Bool) -> (host: NSHostingView<PageRoot>, state: PageState) {
        let state = PageState()
        state.shown = shown
        let host = NSHostingView(rootView: PageRoot(section: s, state: state))
        host.sizingOptions = []
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        addSubview(host)
        host.layer?.opacity = 0
        pages[s] = (host, state)
        return (host, state)
    }
}

/// Window-wide toolbar buttons (Liquid Glass comes with the system toolbar).
struct TopBar: View {
    @ObservedObject var store = ActivityStore.shared
    @Local private var show = false
    @Local private var page = 0

    var body: some View {
        Button { show.toggle() } label: {
            Label("Assistant et notifications", systemImage: store.unread > 0 ? "bell.badge" : "lightbulb.max")
        }
        .help("Assistant et notifications")
        .popover(isPresented: $show) {
            VStack(spacing: 0) {
                Picker("", selection: $page) {
                    Text("Conseils").tag(0)
                    Text(store.unread > 0 ? "Notifications (\(store.unread))" : "Notifications").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top], 18)
                if page == 0 { AssistantView(close: { show = false }) } else { NoticesView(close: { show = false }) }
            }
            .frame(width: 416)
        }
    }
}

/// Tells SystemMonitor whether the main window is really on screen: ordered out, minimized to the Dock
/// or fully hidden (occlusionState not visible) all count as « not visible ».
struct WindowVisibility: NSViewRepresentable {
    @MainActor final class Coordinator {
        var attached = false
        var observers: [NSObjectProtocol] = []
        weak var window: NSWindow?
        func update(closing: Bool = false) {
            // Fenêtre fermée : l'arbre de Stockage (plusieurs dizaines de Mo), les résultats d'analyse, la liste des apps, les icônes
            // de fichiers et les images du thème sont libérés ; le cache sur disque et un clic sur « Analyser » suffisent à les retrouver.
            // Libéré après le retrait du contrôleur SwiftUI (`MainWindow.detachHost`, mis en file plus tôt par la même notification) :
            // libérer pendant que les pages sont encore attachées les faisait toutes se refaire pour rien (≈ 100 ms à la fermeture, rc4).
            if closing {
                DispatchQueue.main.async {
                    StorageModel.shared.release(); Router.shared.live = false; ThemeBackgrounds.shared.release()
                    Sessions.shared.releaseResults(); AppsModel.shared.release(); StartupModel.shared.release(); IconCache.release(); ThemePack.shared.releaseIcons()
                    for d in [2.0, 8.0] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { malloc_zone_pressure_relief(nil, 0) } }
                }
            }
            let on = !closing && (window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false)
            guard on != attached else { return }
            attached = on
            Nav.shared.visible = on
            if on { Router.shared.live = true }
            if on { SystemMonitor.shared.attach() } else { SystemMonitor.shared.detach() }
        }
        func watch(_ w: NSWindow) {
            guard window !== w else { return }
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            window = w
            for n in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                      NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] note in
                    // willClose fires before the window is actually hidden.
                    let closing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated { self?.update(closing: closing) }
                })
            }
            update()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    @MainActor static func dismantleNSView(_ v: NSView, coordinator: Coordinator) { coordinator.update(closing: true) }
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { context.coordinator.watch(w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { context.coordinator.watch(w) } }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { .zero }
}

struct AssistantView: View {
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Assistant", systemImage: "lightbulb.max.fill").font(Typo.headline)
            ForEach(Array(Health.tips().prefix(7).enumerated()), id: \.offset) { _, t in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkle").foregroundStyle(.tint).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.0).fontWeight(.semibold)
                        Text(t.1).font(Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let m = t.2 { Button("Voir") { Router.shared.go(m); close() }.controlSize(.small) }
                }
            }
        }
        .padding(18).frame(width: 416)
    }
}

struct NoticesView: View {
    let close: () -> Void
    @ObservedObject var store = ActivityStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Notifications").font(Typo.headline)
                Spacer()
                if store.unread > 0 { Button("Tout marquer comme lu") { store.markAllRead() }.controlSize(.small) }
            }
            if store.notices.isEmpty {
                Text("Aucune notification pour l'instant.").foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(store.notices.prefix(40)) { n in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(n.read ? AnyShapeStyle(.clear) : AnyShapeStyle(.tint)).frame(width: 7, height: 7).padding(.top, 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(n.title).fontWeight(.semibold)
                                    Text(n.body).font(Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    Text(Fmt.ago(n.date)).font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if let l = n.link, let m = Module(rawValue: l) { Button("Voir") { Router.shared.go(m); close() }.controlSize(.small) }
                            }
                        }
                    }
                }.frame(maxHeight: 380)
            }
        }
        .padding(18).frame(width: 416)
        .onDisappear { store.markAllRead() }
    }
}
