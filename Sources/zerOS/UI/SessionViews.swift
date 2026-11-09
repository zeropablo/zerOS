import SwiftUI
import AppKit

// MARK: - Sous-sections (capsule de verre en haut du contenu)

/// Sélecteur de sous-sections : une capsule de verre dans le contenu, sous la barre d'outils (qui garde de la place pour la recherche).
/// Bulle de sélection en verre natif : ses deux bords glissent ensemble avec `Motion.subsection` (aucun étirement) et restent dans
/// la capsule (`BubbleSpan` : aux extrémités, un dépassement l'écrase contre le bord). Interrompue, elle repart de sa position et de sa vitesse.
struct SubTabBar: View {
    let tabs: [(String, String)]   // id, label
    let selection: String
    let select: (String) -> Void
    @Environment(\.opaqueSurfaces) private var reduceTransparency
    @Environment(\.themeGlassTint) private var tint
    @Local private var frames: [String: CGRect] = [:]
    @Local private var span: (lo: CGFloat, hi: CGFloat) = (0, 0)
    @Local private var length: CGFloat = 0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.0) { t in
                Button { if t.0 != selection { select(t.0) } } label: {
                    Text(t.1).font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(t.0 == selection ? .isSelected : [])
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("subtabs")) } action: { f in
                    frames[t.0] = f
                    if t.0 == selection { span = (f.minX, f.maxX) }
                }
            }
        }
        .background {
            Capsule().fill(reduceTransparency ? AnyShapeStyle(Palette.skyDeep) : AnyShapeStyle(Color.white.opacity(0.14)))
                .glassSurface(reduceTransparency ? .identity : .regular.tint(Palette.aqua.opacity(0.3)).interactive(), in: Capsule())
                .modifier(BubbleSpan(lo: span.lo, hi: span.hi, vertical: false, length: length))
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { length = $0 }
        .coordinateSpace(.named("subtabs"))
        .onChange(of: selection) { _, new in if let f = frames[new] { withAnimation(Motion.subsection) { span = (f.minX, f.maxX) } } }
        .padding(4)
        .background { if reduceTransparency { Capsule().fill(Palette.nightBlue) } }
        .glassSurface(reduceTransparency ? .identity : .regular.tint(Palette.sky.opacity(max(tint, 0.25))), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1).allowsHitTesting(false))
        .padding(.horizontal, Space.panel).padding(.top, 6).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }
}

/// Boutons d'action d'une page (Actualiser, Analyser à nouveau…), en haut du contenu, à droite, et sa recherche à gauche. Rien de tout cela
/// n'est dans la barre d'outils : elle reste identique d'une page à l'autre et n'est jamais remise en page (les pages visitées restent
/// construites, une recherche `.searchable` par page s'y serait ajoutée).
struct PageActionBar<Actions: View>: View {
    var search: Binding<String>? = nil
    var prompt = "Rechercher"
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(spacing: 8) {
            if let search { PageSearchField(text: search, prompt: prompt) }
            Spacer(minLength: 0)
            actions
        }
        .glassButtons().controlSize(.small).labelStyle(.titleAndIcon)
        .padding(.horizontal, Space.panel).padding(.top, 6).padding(.bottom, 6)
    }
}

/// Champ de recherche d'une page : capsule de verre ; Échap ou ⓧ le vide et rend la liste telle qu'avant.
struct PageSearchField: View {
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text).textFieldStyle(.plain).frame(width: 190)
                .accessibilityLabel(prompt)
                .onExitCommand { text = "" }
            Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).opacity(text.isEmpty ? 0 : 1).disabled(text.isEmpty)
                .help("Effacer la recherche").accessibilityLabel("Effacer la recherche")
        }
        .font(Typo.detail)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glassSurface(.regular, in: Capsule())
    }
}

extension View {
    func pageActions<A: View>(@ViewBuilder _ actions: () -> A) -> some View {
        fullPage().safeAreaInset(edge: .top, spacing: 0) { PageActionBar { actions() } }
    }

    /// Barre d'actions avec un champ de recherche à gauche.
    func pageActions<A: View>(search: Binding<String>, prompt: String = "Rechercher", @ViewBuilder _ actions: () -> A) -> some View {
        fullPage().safeAreaInset(edge: .top, spacing: 0) { PageActionBar(search: search, prompt: prompt) { actions() } }
    }

    /// DESIGN.md §12 : une page occupe toujours toute la place, quelle que soit la quantité de contenu (sinon un état vide rétrécit
    /// le panneau et fait descendre la capsule de sous-sections au milieu de l'écran).
    func fullPage() -> some View { frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) }

    /// Pose la capsule de sous-sections en haut du contenu.
    func subTabs(_ tabs: [(String, String)], selection: String, select: @escaping (String) -> Void) -> some View {
        fullPage().morph(key: selection, .subsection).fullPage()
            .safeAreaInset(edge: .top, spacing: 0) { SubTabBar(tabs: tabs, selection: selection) { id in Settle.shared.transition { select(id) } } }
    }

    /// Les onglets d'un module, dans la capsule en haut du contenu.
    func moduleTabs(_ tabs: [(String, String)], selection: Binding<String>) -> some View {
        subTabs(tabs, selection: selection.wrappedValue) { selection.wrappedValue = $0 }
    }
}

/// Sous-sections gardées construites tant que la fenêtre est ouverte (Stockage, Apps) : la première visite construit la vue (ses blocs
/// lourds après la métamorphose, `Settle.transition`), un retour ne reconstruit rien : fondu enchaîné avec flou entre vues gardées
/// (mesuré rc2 : revenir sur Désinstallation reconstruisait la liste, 88 ms). Seule la vue affichée reçoit les clics.
struct TabDeck<Content: View>: View {
    let tabs: [(String, String)]
    let selection: String
    let select: (String) -> Void
    @ViewBuilder let content: (String) -> Content
    @Local private var visited: [String] = []
    /// Visibilité de chaque sous-section gardée (constante par sous-section : seuls les chargements animés l'observent).
    /// Créée à la première construction de la sous-section : la valeur d'environnement ne change jamais ensuite (passer de nil à un
    /// objet après la première image refaisait toute la sous-section, ≈ 60 ms mesurés sur Données système).
    @Local private var states = TabStates()

    var body: some View {
        let keys = visited.contains(selection) ? visited : visited + [selection]
        ZStack {
            ForEach(keys, id: \.self) { k in
                let on = k == selection
                content(k).fullPage()
                    .environment(\.tabState, states[k])
                    .modifier(MorphEffect(opacity: on ? 1 : 0, blur: on || Motion.reduced ? 0 : 6))
                    .allowsHitTesting(on).accessibilityHidden(!on).zIndex(on ? 1 : 0)
                    .transition(.morph)
            }
        }
        .animation(Motion.content, value: selection)
        .fullPage()
        .safeAreaInset(edge: .top, spacing: 0) { SubTabBar(tabs: tabs, selection: selection) { id in Settle.shared.transition { select(id) } } }
        .onChange(of: selection, initial: true) { _, s in
            if !visited.contains(s) { visited.append(s) }
            for (k, st) in states.all where st.shown != (k == s) { st.shown = k == s }
        }
    }
}

/// Visibilité des sous-sections gardées : un objet constant par sous-section, créé à sa première lecture (cache, rien d'observé).
@MainActor
final class TabStates {
    private(set) var all: [String: PageState] = [:]
    subscript(_ k: String) -> PageState {
        if let s = all[k] { return s }
        let s = PageState(); all[k] = s; return s
    }
}

// MARK: - États vides

/// État vide, d'erreur, de permission ou d'attente (DESIGN.md §12) : centré dans l'espace restant, texte factuel sans emoji
/// (zerOS ne parle pas), actions éventuelles dessous.
struct EmptyState<Actions: View>: View {
    let title: String
    var detail: String? = nil
    let symbol: String
    @ViewBuilder var actions: Actions

    init(_ title: String, detail: String? = nil, symbol: String, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.detail = detail; self.symbol = symbol; self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 36)).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
            Text(title).font(Typo.sectionTitle).multilineTextAlignment(.center)
            if let detail { Text(detail).font(Typo.detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480) }
            actions.padding(.top, 4)
        }
        .padding(Space.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(_ title: String, detail: String? = nil, symbol: String) { self.init(title, detail: detail, symbol: symbol) { EmptyView() } }
}

// MARK: - Hero (before scanning)

struct HeroView<Extra: View>: View {
    let module: Module
    let title: String
    let text: String
    let button: String
    var last: Date? = nil
    let action: () -> Void
    @ViewBuilder var extra: Extra
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: module.symbol)
                    .font(.system(size: 64, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(module.tint)
                    .padding(.bottom, 4)
                Text(title).font(Typo.hero).multilineTextAlignment(.center)
                Text(text).font(Typo.sectionTitle).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 520)
                Button(action: action) { Text(button).frame(minWidth: 140) }
                    .buttonStyle(.borderedProminent).controlSize(.extraLarge)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 8)
                if let last { Text("Dernière analyse \(Fmt.ago(last))").font(Typo.detail).foregroundStyle(.secondary) }
                extra.frame(maxWidth: 600).padding(.top, 8)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
    }
}

extension HeroView where Extra == EmptyView {
    init(module: Module, title: String, text: String, button: String, last: Date? = nil, action: @escaping () -> Void) {
        self.module = module; self.title = title; self.text = text; self.button = button; self.last = last; self.action = action; self.extra = EmptyView()
    }
}

struct BusyView: View {
    let module: Module
    let title: String
    let status: String
    var body: some View {
        VStack(spacing: 16) {
            LiquidRing(size: 72)
            Text(title).font(Typo.value)
            Text(status).font(Typo.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DoneView: View {
    let module: Module
    let report: CleanReport
    var verb = "libérés"
    let back: () -> Void
    let again: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).symbolRenderingMode(.hierarchical).foregroundStyle(.green)
            Text("Terminé").font(Typo.hero)
            if report.freed > 0 {
                Text("\(Fmt.bytes(report.freed)) \(verb)").font(Typo.value).foregroundStyle(module.tint)
            }
            Text(Fmt.count(report.count, "élément traité", "éléments traités")).foregroundStyle(.secondary)
            if !report.errors.isEmpty {
                GroupBox {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(report.errors.prefix(40).enumerated()), id: \.offset) { Text($0.element).font(Typo.detail).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                } label: {
                    Label("Quelques éléments n'ont pas pu être traités", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .frame(maxWidth: 560)
            }
            HStack(spacing: 12) {
                Button("Revoir les résultats", action: back).controlSize(.large)
                PrimaryButton(title: "Nouvelle analyse", symbol: "arrow.clockwise", action: again)
            }.padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Generic scan → review → clean page

struct SessionPage<Extra: View>: View {
    let module: Module
    @ObservedObject var session: ScanSession
    let heroTitle: String
    let heroText: String
    var scanLabel = "Analyser"
    @ViewBuilder var extra: Extra

    var body: some View {
        Group { page }
            .animation(Motion.content, value: session.phase)
    }

    @ViewBuilder var page: some View {
        switch session.phase {
        case .idle:
            HeroView(module: module, title: heroTitle, text: heroText, button: scanLabel, last: session.lastScan, action: session.scan) { extra }
        case .scanning:
            BusyView(module: module, title: "Analyse en cours…", status: session.status)
        case .results:
            if session.groups.isEmpty {
                EmptyState(session.emptyMessage, detail: "Analyse \(Fmt.ago(session.lastScan)).", symbol: "checkmark.seal") {
                    Button("Analyser à nouveau", action: session.scan)
                }
            } else {
                Deferred { ResultsView(module: module, session: session) }
            }
        case .working:
            BusyView(module: module, title: "Nettoyage en cours…", status: session.status)
        case .done:
            DoneView(module: module, report: session.report, back: session.backToResults, again: session.scan)
        }
    }
}

extension SessionPage where Extra == EmptyView {
    init(module: Module, session: ScanSession, heroTitle: String, heroText: String, scanLabel: String = "Analyser") {
        self.module = module; self.session = session; self.heroTitle = heroTitle; self.heroText = heroText; self.scanLabel = scanLabel; self.extra = EmptyView()
    }
}

struct ResultsView: View {
    let module: Module
    @ObservedObject var session: ScanSession
    /// Action en attente de confirmation : mode imposé par le bouton (nil = bouton principal) et texte du plan (liste et taille).
    @Local private var pending: (mode: RemovalMode?, title: String, plan: String)?

    /// Groups with nothing in them (0 o) are not worth a row.
    var groups: [CleanGroup] { session.groups.filter { $0.size > 0 } }
    var focused: CleanGroup? { groups.first { $0.id == session.focusedGroup } ?? groups.first }

    /// Toute action est confirmée avec ce qu'elle va faire (nombre, taille, Corbeille ou définitif, éléments).
    func ask(_ mode: RemovalMode?, _ title: String) {
        let items = session.itemsToRun(mode: mode)
        guard !items.isEmpty else { return }
        pending = (mode, title, CleanPlan.summary(items))
    }

    var body: some View {
        HStack(spacing: 0) {
            List(groups, selection: $session.focusedGroup) { g in
                GroupRow(group: g, session: session).tag(g.id).themeRow()
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Fmt.bytes(session.totalSize)) trouvés").font(Typo.sectionTitle)
                    Text("\(Fmt.count(session.allItems.count, "élément")) · analyse \(Fmt.ago(session.lastScan))").font(Typo.detail).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.panel).padding(.vertical, 10)
            }
            .frame(width: 340)
            Divider()
            Group { if let g = focused { ItemsPane(group: g, session: session) } else { Spacer() } }
                .frame(minWidth: 420, maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FloatingBar {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sélection : \(Fmt.bytes(session.selectedSize))").font(Typo.headline).monospacedDigit()
                        .contentTransition(.numericText()).animation(Motion.detail, value: session.selectedSize)
                    Text(Fmt.count(session.selected.count, "élément coché", "éléments cochés")).font(Typo.detail).foregroundStyle(.secondary)
                }
                Spacer()
                ForEach(Array(session.extraActions.enumerated()), id: \.offset) { i, a in
                    Button(a.title) { ask(a.mode, a.title) }
                        .controlSize(.large).disabled(session.selected.isEmpty)
                }
                if let s = session.secondary {
                    Button(s.title) { ask(s.mode, s.title) }.controlSize(.large).disabled(session.selected.isEmpty)
                }
                PrimaryButton(title: session.primaryTitle, disabled: session.selected.isEmpty) { ask(nil, session.primaryTitle) }
            }
        }
        .pageActions(search: $session.search) {
            Menu {
                Button("Tout cocher") { session.selectAll(true) }
                Button("Tout décocher") { session.selectAll(false) }
            } label: { Label("Sélection", systemImage: "checklist") }
            .help("Tout cocher ou tout décocher")
            Button { session.scan() } label: { Label("Analyser à nouveau", systemImage: "arrow.clockwise") }
                .help("Analyser à nouveau")
        }
        .alert("\(pending?.title ?? "") ?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Annuler", role: .cancel) { pending = nil }
            Button(pending?.title ?? "Continuer", role: .destructive) { if let p = pending { session.run(mode: p.mode) }; pending = nil }
        } message: {
            Text(pending?.plan ?? "")
        }
    }
}

struct GroupRow: View {
    let group: CleanGroup
    @ObservedObject var session: ScanSession
    var body: some View {
        HStack(spacing: 8) {
            Checkbox(state: session.groupState(group), disabled: group.infoOnly) { session.toggleGroup(group) }
            Image(systemName: group.symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title).lineLimit(1)
                Text(group.infoOnly ? "Analyse seule" : group.subtitle).font(Typo.detail).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(Fmt.bytes(group.infoOnly ? group.size : session.groupSize(group))).monospacedDigit()
                .foregroundStyle(group.infoOnly ? .secondary : .primary)
        }
        .padding(.vertical, 3)
    }
}

struct ItemsPane: View {
    let group: CleanGroup
    @ObservedObject var session: ScanSession

    var items: [CleanItem] {
        let q = session.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return group.items }
        return group.items.filter { $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Checkbox(state: session.groupState(group), disabled: group.infoOnly) { session.toggleGroup(group) }
                    Text(group.title).font(Typo.sectionTitle)
                    Spacer()
                    Text(Fmt.bytes(group.size)).foregroundStyle(.secondary).monospacedDigit()
                }
                if let n = group.note { Text(n).font(Typo.detail).foregroundStyle(.secondary).lineLimit(8) }
            }
            .padding(.horizontal, Space.panel).padding(.vertical, 12)
            Divider()
            List(items) { item in ItemRow(item: item, group: group, session: session).themeRow() }
                .listStyle(.inset)
                .animation(Motion.detail, value: session.search)
        }
    }
}

struct ItemRow: View {
    let item: CleanItem
    let group: CleanGroup
    @ObservedObject var session: ScanSession
    var body: some View {
        HStack(spacing: 10) {
            Checkbox(state: session.isSelected(item), disabled: !item.actionable || group.infoOnly) { session.toggle(item) }
            ItemIcon(path: item.iconPath, symbol: item.symbol ?? group.symbol, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                    if item.readOnly {
                        Image(systemName: "lock.fill").font(Typo.caption).foregroundStyle(.secondary)
                            .help("Dossier protégé : analyse seulement, rien n'y est supprimé.")
                            .accessibilityLabel("Lecture seule")
                    }
                }
                if !item.subtitle.isEmpty { Text(item.subtitle).font(Typo.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 8)
            if let d = item.date { Text(Fmt.date(d)).font(Typo.detail).foregroundStyle(.secondary) }
            Text(item.size > 0 ? Fmt.bytes(item.size) : "—").monospacedDigit().frame(width: 76, alignment: .trailing)
            if let u = item.url {
                Button { FS.reveal(u) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Afficher dans le Finder")
            }
            InsightButton(title: item.title, path: item.url?.path, context: group.title)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.detail) { session.toggle(item) } }
        .contextMenu {
            if let u = item.url {
                Button("Afficher dans le Finder") { FS.reveal(u) }
                Button("Ne plus jamais proposer cet élément") { Ignore.add(u.path); session.selected.remove(item.id) }
            }
        }
    }
}
