import SwiftUI
import AppKit

/// Icône de zerOS dans la barre des menus (`NSStatusItem` géré par zerOS) : un clic ouvre le panneau (`MenuPanel`) dans un popover.
/// La bulle d'alerte se place sous cette même icône (`iconFrame`), sans passer par aucune classe interne d'AppKit.
@MainActor
final class StatusBar: NSObject, NSPopoverDelegate {
    static let shared = StatusBar()

    private(set) var item: NSStatusItem?
    private var popover: NSPopover?
    private var closedAt = Date.distantPast

    var isInstalled: Bool { item != nil }

    func install() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = it.button {
            // Image modèle du thème (18 pt, teintée par macOS) ; repli : symbole de la machine.
            // Les trois tailles (@1x, @2x, @3x) dans une seule image : chaque écran prend la sienne, sans mise à l'échelle.
            var img: NSImage? = ThemePack.shared.root.flatMap { root in
                let reps = ["1x", "2x", "3x"].compactMap { NSImageRep(contentsOf: root.appendingPathComponent("menubar/zerOS-menubar@\($0).png")) }
                guard !reps.isEmpty else { return nil }
                let i = NSImage(size: NSSize(width: 18, height: 18))
                for r in reps { r.size = NSSize(width: 18, height: 18); i.addRepresentation(r) }
                return i
            }
            if img == nil { img = NSImage(systemSymbolName: Machine.symbol, accessibilityDescription: "zerOS") }
            img?.isTemplate = true
            b.image = img
            b.target = self
            b.action = #selector(toggle)
            b.toolTip = "zerOS"
            b.setAccessibilityLabel("zerOS")
        }
        item = it
    }

    func remove() {
        popover?.close()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// Cadre de l'icône en coordonnées d'écran (nil si l'icône n'est pas affichée).
    var iconFrame: NSRect? {
        guard let w = item?.button?.window, w.isVisible else { return nil }
        let f = w.frame
        return f.width > 0 && f.height > 0 ? f : nil
    }

    var screen: NSScreen? { item?.button?.window?.screen }

    /// Icône réellement visible : macOS cache celles qui ne tiennent pas dans la barre des menus (barre pleine, ou sous l'encoche des
    /// MacBook, entre les deux zones de part et d'autre de la caméra). Essai : `--simulate-hidden-icon`.
    var iconVisible: Bool {
        guard !CommandLine.arguments.contains("--simulate-hidden-icon"), let w = item?.button?.window, w.isVisible,
              w.occlusionState.contains(.visible), let s = w.screen, s.frame.intersects(w.frame) else { return false }
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea, w.frame.midX > l.maxX, w.frame.midX < r.minX { return false }
        return true
    }

    private var reminded = false
    /// zerOS ouvert depuis le Dock, le Launchpad ou le Finder alors que son icône est cachée : rappel dans la cloche (une fois par lancement)
    /// qu'elle existe et comment lui faire de la place.
    func remindIfHidden() {
        guard isInstalled, !reminded else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            guard !iconVisible, !reminded else { return }
            reminded = true
            ActivityStore.shared.record("L'icône de zerOS est cachée",
                "La barre des menus n'a plus de place (ou l'icône est sous l'encoche de l'écran). Pour la faire réapparaître : maintenez ⌘ et glissez d'autres icônes hors de la barre, ou retirez-en dans Réglages Système > Barre des menus. zerOS s'ouvre aussi depuis le Dock et le Launchpad.")
        }
    }

    /// Ouvre le panneau (captures : `--demo-panel`).
    func showPanel() { if popover?.isShown != true { toggle() } }

    @objc private func toggle() {
        if let p = popover, p.isShown { p.performClose(nil); return }
        // Le clic sur l'icône ferme d'abord le popover (comportement « transient ») : ne pas le rouvrir aussitôt.
        guard Date().timeIntervalSince(closedAt) > 0.25, let button = item?.button else { return }
        let host = NSHostingController(rootView: MenuPanel().accessibilityRoot())
        host.sizingOptions = .preferredContentSize
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = host
        p.delegate = self
        popover = p
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
    }

    func close() { popover?.performClose(nil) }

    // MARK: NSPopoverDelegate

    nonisolated func popoverWillShow(_ notification: Notification) {
        MainActor.assumeIsolated { SystemMonitor.shared.attach(); SystemMonitor.shared.setLive("panel", true); MenuBubble.shared.panelOpen = true }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            SystemMonitor.shared.setLive("panel", false); SystemMonitor.shared.detach(); MenuBubble.shared.panelOpen = false
            closedAt = Date()
            // Rien ne reste en mémoire quand le panneau est fermé.
            popover?.contentViewController = nil
            popover = nil
        }
    }
}
