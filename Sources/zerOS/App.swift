import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

enum Module: String, CaseIterable, Identifiable, Hashable {
    case smartCare, cleanup, performance, applications, clutter, spaceLens, systemData, relocate, cloud, activity
    var id: String { rawValue }
}

/// Les 6 sections de SPEC.md, dans l'ordre fixe. Les pages ne dépendent pas de la navigation :
/// seule la coquille (`MainView`) lit `Router.section`, elle peut être remplacée sans toucher aux pages.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case today, storage, apps, health, journal
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Aujourd'hui"
        case .storage: "Stockage"
        case .apps: "Apps"
        case .health: "Santé"
        case .journal: "Journal"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .storage: "internaldrive"
        case .apps: "square.grid.2x2"
        case .health: "heart.text.square"
        case .journal: "list.bullet.clipboard"
        }
    }

    /// Sous-vues provisoires (ancien module → identifiant), pour Stockage.
    var subviews: [(Module, String)] {
        switch self {
        case .storage: [(.cleanup, "Nettoyage"), (.spaceLens, "Arborescence"), (.systemData, "Données système"), (.relocate, "Déplacer"), (.clutter, "Mon désordre"), (.cloud, "Cloud")]
        default: []
        }
    }

    /// Section qui contient désormais l'ancien module.
    static func containing(_ m: Module) -> AppSection {
        switch m {
        case .smartCare: .today
        case .cleanup, .clutter, .spaceLens, .systemData, .relocate, .cloud: .storage
        case .performance: .health
        case .applications: .apps
        case .activity: .journal
        }
    }
}

/// Ce que la coquille de la fenêtre lit (section affichée, fenêtre vivante, sections de la navigation). Séparé de `Router` : changer de
/// sous-vue ou d'onglet ne doit pas refaire la barre latérale, le fond et la barre d'outils.
@MainActor @Observable
final class Nav {
    static let shared = Nav()
    var section: AppSection = .today
    /// Faux quand la fenêtre est fermée : `MainView` défait alors tout son contenu.
    var live = true
    /// Fenêtre principale en plein écran (intitulé du menu Présentation).
    var fullScreen = false
    /// Vrai quand la fenêtre est réellement à l'écran (ni fermée, ni cachée, ni réduite) : les chargements liquides ne s'animent que là.
    var visible = false

    /// Change la section affichée (ignorée si elle n'est pas dans la navigation).
    func select(_ s: AppSection) {
        guard visibleSections.contains(s), s != section else { return }
        section = s
    }

    var visibleSections: [AppSection] { AppSection.allCases }
}

@MainActor @Observable
final class Router {
    static let shared = Router()
    var section: AppSection {
        get { Nav.shared.section }
        set { Nav.shared.select(newValue) }
    }
    var live: Bool {
        get { Nav.shared.live }
        set { Nav.shared.live = newValue }
    }
    /// Sous-vue choisie dans Stockage.
    var sub: [AppSection: Module] = [.storage: .cleanup]
    var tabs: [Module: String] = [:]

    /// Ouvre l'ancien module à sa nouvelle place (section + sous-vue).
    func go(_ m: Module, tab: String? = nil) {
        if let tab { tabs[m] = tab }
        let s = AppSection.containing(m)
        if !s.subviews.isEmpty { sub[s] = m }
        section = s
        MainWindow.shared.show()
    }

    func tab(_ m: Module, default d: String) -> Binding<String> {
        Binding(get: { self.tabs[m] ?? d }, set: { self.tabs[m] = $0 })
    }
}

@main
struct ZerOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            exit(0)
        }
    }

    /// La fenêtre principale (`MainWindow`), l'icône de la barre des menus (`StatusBar`) et l'assistant (`Wizard`) sont gérés par zerOS lui-même
    /// (AppKit) : seules les Réglages passent par une scène SwiftUI.
    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands { NavCommands(); WindowCommands() }
    }
}

/// Fenêtre principale. Créée à la demande (jamais au lancement par l'ouverture de session), réutilisée ensuite ; sa position est mémorisée.
@MainActor
final class MainWindow {
    static let shared = MainWindow()
    private var window: NSWindow?
    private var host: NSHostingController<AnyView>?
    private let delegate = ShellWindowDelegate()

    var isVisible: Bool { window?.isVisible == true }

    func close() { window?.close() }

    /// Présentation > plein écran : la fenêtre principale, ouverte d'abord si besoin.
    func toggleFullScreen() {
        if window?.isVisible != true { show() }
        window?.toggleFullScreen(nil)
    }

    /// Ouvre (ou ramène) la fenêtre. Sans configuration, l'assistant de premier lancement passe d'abord.
    func show() {
        if Config.needsWizard, !Wizard.shared.isOpen { Wizard.shared.show(); return }
        openIgnoringWizard()
    }

    /// Ouvre la fenêtre même sans configuration (assistant fermé sans être terminé).
    func openIgnoringWizard() {
        Router.shared.live = true
        if window == nil { build() }
        // Fenêtre fermée : le contenu SwiftUI est défait pour de bon (une fenêtre cachée ne rafraîchit plus rien, l'arbre de Stockage
        // et les dispositions des anneaux restaient sinon retenus par la hiérarchie de vues) ; il est recréé ici.
        if host == nil, let w = window { attachHost(w) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let rect = NSRect(x: 0, y: 0, width: 1180, height: 760)
        let w = WindowLog.on ? LoggedWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
            : ShellWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        WindowLog.watch(w)
        attachHost(w)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.title = "zerOS"
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 1180, height: 760))
        w.contentMinSize = Self.minSize
        if !w.setFrameUsingName("main") { w.center() }
        // Petit écran simulé : la position mémorisée n'est pas remplacée par celle de l'essai.
        if Self.simulatedScreen == nil { w.setFrameAutosaveName("main") }
        window = w
        fit(w)
        ThemeBackgrounds.shared.screen(w.screen)
        // Écran changé (glissement, écran débranché) ou échelle / profil changé (Retina ↔ écran 1x) : fond redécodé pour cet écran.
        for n in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak w] _ in
                MainActor.assumeIsolated { ThemeBackgrounds.shared.screen(w?.screen) }
            }
        }
        // Écran débranché ou résolution changée pendant que la fenêtre est ouverte : elle reste entière sur un écran présent.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self, weak w] _ in
            MainActor.assumeIsolated { if let w, w.isVisible { self?.fit(w) } }
        }
        w.delegate = delegate
        if CommandLine.arguments.contains("--demo-fullscreen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak w] in w?.toggleFullScreen(nil) }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Après les libérations de `WindowVisibility` (même notification) : le contrôleur SwiftUI est retiré de la fenêtre.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.detachHost() } }
            }
        }
    }

    private static func content(_ min: NSSize = minSize) -> AnyView { AnyView(MainView().frame(minWidth: min.width, minHeight: min.height)) }

    /// Taille minimale du contenu (sauf écran plus petit, voir `fit`).
    nonisolated static let minSize = NSSize(width: 940, height: 620)

    /// Espace utile simulé (`--simulate-screen=1024x665` : écran de 1024 × 665 points, barre des menus à encoche de 37 points et Dock de
    /// 64 points en bas), posé dans le coin haut gauche de l'écran réel : contrôle d'un petit écran sans en avoir un.
    private static let simulatedScreen: NSSize? = {
        guard let a = CommandLine.arguments.first(where: { $0.hasPrefix("--simulate-screen=") }) else { return nil }
        let v = a.dropFirst(18).split(separator: "x").compactMap { Double($0) }
        return v.count == 2 ? NSSize(width: v[0], height: v[1] - 37 - 64) : nil
    }()

    /// La fenêtre entière sur un écran présent : position mémorisée sur un écran débranché depuis (elle revient sur l'écran qui en
    /// contient le plus, sinon celui de la barre des menus), écran plus petit que la fenêtre (taille et taille minimale réduites à
    /// l'espace utile : MacBook Air 13" en « Texte plus grand », 1024 × 665 points). Jamais en plein écran.
    private func fit(_ w: NSWindow) {
        guard !w.styleMask.contains(.fullScreen), let first = NSScreen.screens.first else { return }
        let f = w.frame
        func area(_ r: NSRect) -> CGFloat { let i = r.intersection(f); return i.isNull ? 0 : i.width * i.height }
        var vis = NSScreen.screens.map(\.visibleFrame).max { area($0) < area($1) } ?? first.visibleFrame
        if area(vis) == 0 { vis = first.visibleFrame }
        if let s = Self.simulatedScreen { vis = NSRect(x: vis.minX, y: vis.maxY - s.height, width: s.width, height: s.height) }
        let min = NSSize(width: Swift.min(Self.minSize.width, vis.width), height: Swift.min(Self.minSize.height, vis.height))
        if w.contentMinSize != min {
            // La hauteur minimale de SwiftUI compte sous la barre d'outils (zone sûre) : la fenêtre fait elle 52 points de plus.
            w.contentMinSize = min
            host?.rootView = Self.content(NSSize(width: min.width, height: Swift.min(Self.minSize.height, vis.height - Rail.toolbarHeight)))
        }
        var r = f
        r.size = NSSize(width: Swift.min(f.width, vis.width), height: Swift.min(f.height, vis.height))
        r.origin.x = Swift.min(Swift.max(f.minX, vis.minX), vis.maxX - r.width)
        r.origin.y = Swift.min(Swift.max(f.minY, vis.minY), vis.maxY - r.height)
        if r != f { w.setFrame(r, display: true) }
    }

    private func attachHost(_ w: NSWindow) {
        let h = NSHostingController(rootView: Self.content(w.contentMinSize == .zero ? Self.minSize : w.contentMinSize))
        h.sizingOptions = []
        host = h
        w.contentViewController = h
        w.setContentSize(NSSize(width: 1180, height: 760))
        if !w.setFrameUsingName("main") { w.center() }
        if window != nil { fit(w) }
    }

    /// Fermée, la fenêtre n'a plus aucune vue SwiftUI (une fenêtre cachée ne rafraîchit rien : sinon la hiérarchie retient l'arbre de Stockage).
    private func detachHost() {
        window?.contentViewController = nil
        host = nil
    }
}

/// Fenêtre principale. Barre de titre transparente (le fond du thème passe dessous) : avec elle, macOS 27 décale la fenêtre d'une largeur
/// d'écran quand on la glisse d'un écran à l'autre (« Les écrans disposent de Spaces distincts ») : à l'arrivée du déplacement
/// (`_windowMoved:` → `_setFrameAfterMove:` → `_setFrame:fromAdjustmentToScreen:`), AppKit pose un cadre recalé pour le nouvel écran au lieu
/// de celui où le curseur l'a amenée, et le décalage reste jusqu'au bout du glissement. Reproduit sur une fenêtre AppKit nue (seul réglage en
/// commun : `titlebarAppearsTransparent`), jamais avec une barre de titre ordinaire (UX-AUDIT.md §0). Pendant un glissement à la souris,
/// le cadre posé est donc celui où le serveur de fenêtres a réellement mis la fenêtre ; partout ailleurs (menu Fenêtre > Déplacer vers…,
/// écran débranché, Mission Control), le recalage d'AppKit reste tel quel.
class ShellWindow: NSWindow {
    private func dragged(_ r: NSRect) -> NSRect {
        guard let e = NSApp.currentEvent, e.type == .appKitDefined, e.subtype == .windowMoved, NSEvent.pressedMouseButtons & 1 != 0,
              r.size == frame.size,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowNumber)) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] as? NSDictionary, let s = CGRect(dictionaryRepresentation: b), s.size == r.size,
              let h = NSScreen.screens.first?.frame.height else { return r }
        return NSRect(x: s.minX, y: h - s.maxY, width: s.width, height: s.height)
    }
    override func setFrame(_ r: NSRect, display: Bool) { super.setFrame(dragged(r), display: display) }
    override func setFrame(_ r: NSRect, display: Bool, animate: Bool) { super.setFrame(dragged(r), display: display, animate: animate) }
}

/// zerOS ouvert directement depuis l'image disque (volume en lecture seule) ou depuis un dossier isolé par macOS (App Translocation : une app
/// téléchargée lancée sans avoir été déplacée) : l'accès complet au disque et l'ouverture à la session y sont attachés à une copie
/// provisoire. Un message le dit avant tout le reste. Essai : `--simulate-translocation`.
@MainActor
enum Installed {
    static var outsideApplications: Bool {
        if CommandLine.arguments.contains("--simulate-translocation") { return true }
        let url = Bundle.main.bundleURL
        if url.path.contains("/AppTranslocation/") { return true }
        return (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
    }

    static func warn() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Glissez zerOS dans Applications"
        a.informativeText = "zerOS est ouvert directement depuis l'image disque. Pour que l'accès complet au disque et l'ouverture à la session fonctionnent, quittez zerOS, glissez-le dans le dossier Applications, puis ouvrez-le depuis là."
        a.addButton(withTitle: "Quitter et ouvrir Applications")
        a.addButton(withTitle: "Continuer quand même")
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
            NSApp.terminate(nil)
        }
    }
}

/// Plein écran : la barre d'outils (la cloche) n'apparaît qu'avec la barre des menus, au survol du haut de l'écran, comme Safari ou Plans ;
/// affichée en permanence, elle passait dans une fenêtre à part posée sur le fond sombre de la fenêtre (bande noire sur le titre).
final class ShellWindowDelegate: NSObject, NSWindowDelegate {
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposed.union([.fullScreen, .autoHideMenuBar, .autoHideToolbar])
    }
    func windowDidEnterFullScreen(_ notification: Notification) { MainActor.assumeIsolated { Nav.shared.fullScreen = true } }
    func windowDidExitFullScreen(_ notification: Notification) { MainActor.assumeIsolated { Nav.shared.fullScreen = false } }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Mode outil de make_dmg.sh : seulement la fenêtre du fond du .dmg, rien d'autre ne démarre.
        if let i = CommandLine.arguments.firstIndex(of: "--render-dmg-background"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { DmgBackground.run(CommandLine.arguments[i + 1]) }
            return
        }
        // Lancé par l'ouverture de session : l'événement d'ouverture porte « keyAELaunchedAsLogInItem ».
        let ev = NSAppleEventManager.shared().currentAppleEvent
        let login = ev?.eventID == kAEOpenApplication
            && ev?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let args = CommandLine.arguments
        MainActor.assumeIsolated {
            // Thème présent : contenu en sombre (DESIGN.md), et toute l'app avec lui (Réglages, alertes, panneau, menus, assistant),
            // comme Logic Pro ou Final Cut Pro ; sinon la fenêtre sombre côtoyait des Réglages et des alertes clairs en mode clair.
            if ThemePack.shared.hasBackgrounds { NSApp.appearance = NSAppearance(named: .darkAqua) }
            if Installed.outsideApplications { Installed.warn() }
            // Réglages de la 0.9 repris une fois ; sans réglage du tout (premier lancement), l'assistant s'ouvre.
            Config.bootstrap()
            if Prefs.store.object(forKey: "menuEnabled") as? Bool ?? true { StatusBar.shared.install() }
            // Fenêtre jamais ouverte d'office à l'ouverture de session (icône seule) ; sans icône dans la barre des menus, elle s'ouvre toujours.
            if args.contains("--wizard") { Wizard.shared.show(forced: true, step: args.compactMap { $0.hasPrefix("--wizard-step=") ? Int($0.dropFirst(14)) : nil }.first ?? 0) }
            else if !login || !StatusBar.shared.isInstalled { MainWindow.shared.show(); StatusBar.shared.remindIfHidden() }
        }
        MainActor.assumeIsolated { MenuDump.run() }
        Notifier.setup()
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            SystemMonitor.shared.start()
            TrashWatcher.shared.start()
        }
        // Ouverture à la session activée par défaut, une seule fois (SPEC.md : sinon les disques branchés et les alertes ne sont
        // pas vus tant que zerOS n'a pas été ouvert). Seulement pour la copie installée ; le réglage reste désactivable.
        if !UserDefaults.standard.bool(forKey: "launchAtLoginDefaultApplied"), Bundle.main.bundlePath.hasPrefix("/Applications/") {
            UserDefaults.standard.set(true, forKey: "launchAtLoginDefaultApplied")
            try? SMAppService.mainApp.register()
        }
        // Captures : `--section=health` ouvre directement une section.
        if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--section=") }), let s = AppSection(rawValue: String(a.dropFirst(10))) {
            Task { @MainActor in Router.shared.section = s }
        }
        if CommandLine.arguments.contains("--frame-log") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { FrameLog.shared.start(on: NSApp.windows.first { $0.isVisible }) } }
        if CommandLine.arguments.contains("--hang-log") { HangLog.shared.start() }
        if CommandLine.arguments.contains("--demo-tour") { DemoTour.run() }
        if CommandLine.arguments.contains("--demo-sections") { DemoSections.run() }
        if CommandLine.arguments.contains("--demo-test5") { DemoTest5.run() }
        // Capture : Stockage > Mon désordre > Téléchargements, analyse lancée (lecture seule).
        if CommandLine.arguments.contains("--demo-downloads") {
            Task { @MainActor in
                Router.shared.sub[.storage] = .clutter; Router.shared.tabs[.clutter] = "downloads"; Router.shared.section = .storage
                AppSessions.downloads.scan()
            }
        }
        // Captures publiques : Stockage > Nettoyage, analyse lancée (avec `--demo-public` : données génériques).
        if CommandLine.arguments.contains("--demo-cleanup") {
            Task { @MainActor in
                Router.shared.sub[.storage] = .cleanup; Router.shared.section = .storage
                AppSessions.cleanup.scan()
            }
        }
        if CommandLine.arguments.contains("--demo-liquid") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { LiquidDemo.show() } }
        // Mesures de mémoire : `--sub=spaceLens` ouvre une sous-vue de Stockage, `--close-after=N` ferme la fenêtre N s après le lancement.
        if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--sub=") }), let m = Module(rawValue: String(a.dropFirst(6))) {
            Task { @MainActor in Router.shared.sub[AppSection.containing(m)] = m }
        }
        if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--close-after=") }), let n = Double(a.dropFirst(14)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + n) { MainWindow.shared.close() }
        }
        // Mesures du repos : `--goto=today@3` change de section 3 s après le lancement (page quittée pendant un chargement).
        if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--goto=") }), case let p = a.dropFirst(7).split(separator: "@"),
           p.count == 2, let s = AppSection(rawValue: String(p[0])), let n = Double(p[1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + n) { Nav.shared.select(s) }
        }
        if CommandLine.arguments.contains("--demo-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.activate(ignoringOtherApps: true); StatusBar.shared.showPanel() }
        }
        // Contrôle visuel de la bulle (jamais utilisé en fonctionnement normal).
        if CommandLine.arguments.contains("--demo-bubble") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MenuBubble.shared.show(Alert(id: "demo", channel: .bubble, title: "Nettoyage terminé", body: "Caches : 1,2 Go supprimés", link: .activity))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            guard let v = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in
                Config.invalidate(); Config.sync()
                _ = v
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { _ in
            Config.invalidate()
        }
        // « Afficher zerOS dans la barre des menus » (Réglages) : l'icône apparaît ou disparaît tout de suite.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let on = Prefs.store.object(forKey: "menuEnabled") as? Bool ?? true
                if on != StatusBar.shared.isInstalled { on ? StatusBar.shared.install() : StatusBar.shared.remove() }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clic sur l'icône du Dock ou nouvelle ouverture depuis le Finder : la fenêtre revient (elle n'est jamais ouverte d'office).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !flag { MainWindow.shared.show() }
            StatusBar.shared.remindIfHidden()
        }
        return true
    }
}
