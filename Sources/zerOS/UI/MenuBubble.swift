import SwiftUI
import AppKit

/// Petite bulle sous l'icône zerOS de la barre des menus : elle disparaît seule (SPEC.md, Notifications). Ce n'est pas une notification Apple.
/// La bulle est une petite fenêtre placée sous l'icône de zerOS (`StatusBar`, un `NSStatusItem` géré par zerOS). Si l'icône n'est pas affichée
/// (réglage décoché, barre des menus pleine), l'alerte reste dans la liste des notifications (cloche) et rien d'autre n'est affiché.
@MainActor
final class MenuBubble {
    static let shared = MenuBubble()
    static let duration: TimeInterval = 6

    /// Vrai pendant que le panneau de la barre des menus est ouvert : pas de bulle par-dessus.
    var panelOpen = false

    private var panel: NSPanel?
    private var queue: [Alert] = []
    private var hide: DispatchWorkItem?

    /// Cadre de l'icône (nil si elle n'est pas affichée).
    static func anchor() -> NSRect? { StatusBar.shared.iconFrame }

    /// Coin bas-gauche de la bulle : centrée sous l'icône, sans sortir de l'écran.
    nonisolated static func origin(icon: NSRect, size: NSSize, screen: NSRect) -> NSPoint {
        NSPoint(x: min(max(icon.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8), y: icon.minY - size.height - 6)
    }

    func show(_ a: Alert) {
        guard !panelOpen, Self.anchor() != nil else { return }
        queue.append(a)
        if panel == nil { next() }
    }

    private func next() {
        guard !queue.isEmpty, let icon = Self.anchor() else { queue = []; return }
        let a = queue.removeFirst()
        let host = NSHostingView(rootView: BubbleView(alert: a) { [weak self] in
            self?.dismiss()
            if let m = a.link { Router.shared.go(m) }
        }.accessibilityRoot())
        let size = host.fittingSize
        let screen = StatusBar.shared.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let origin = Self.origin(icon: icon, size: size, screen: screen)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = Motion.windowIn; p.animator().alphaValue = 1 }
        panel = p
        let w = DispatchWorkItem { [weak self] in self?.dismiss() }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: w)
    }

    private func dismiss() {
        hide?.cancel(); hide = nil
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = Motion.windowOut; p.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated {
                p.orderOut(nil); p.contentView = nil
                if self.panel === p { self.panel = nil; self.next() }
            }
        })
    }
}

struct BubbleView: View {
    let alert: Alert
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.title).font(Typo.headline)
                Text(alert.body).font(Typo.detail).foregroundStyle(.secondary).lineLimit(4)
            }
            .frame(width: 280, alignment: .leading)
            .padding(Space.gap)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
