import AppKit

/// Journal du cadre de la fenêtre principale (`--log-window-frames`, jamais en fonctionnement normal) : chaque changement de cadre demandé
/// par l'app (avec sa pile d'appels), chaque mise au premier plan, les notifications d'écran / d'occlusion / d'échelle / de déplacement et
/// les bascules de `Nav.visible` / `Nav.live`, dans `FS.support/window-frames.txt`.
@MainActor
enum WindowLog {
    static let on = CommandLine.arguments.contains("--log-window-frames")
    private static let url = FS.support.appendingPathComponent("window-frames.txt")
    private static var handle: FileHandle?
    private static let start = CACurrentMediaTime()
    private static var observers: [NSObjectProtocol] = []

    static func note(_ text: String, stack: Bool = false) {
        guard on else { return }
        if handle == nil {
            try? FileManager.default.createDirectory(at: FS.support, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data("# cadre de la fenêtre principale : t(s) événement\n".utf8))
            handle = try? FileHandle(forWritingTo: url); handle?.seekToEndOfFile()
        }
        var s = String(format: "%9.3f ", CACurrentMediaTime() - start) + text + "\n"
        if stack {
            // Les 2 premiers cadres sont `note` et la méthode surchargée ; le reste dit qui a demandé le changement.
            for f in Thread.callStackSymbols.dropFirst(2).prefix(28) { s += "        " + f + "\n" }
        }
        handle?.write(Data(s.utf8))
    }

    static func describe(_ r: NSRect) -> String { "(\(Int(r.minX)), \(Int(r.minY))) \(Int(r.width))×\(Int(r.height))" }
    static func describe(_ s: NSScreen?) -> String {
        guard let s else { return "écran ?" }
        return "écran \(s.localizedName) \(describe(s.frame)) ×\(s.backingScaleFactor)"
    }

    /// Notifications de la fenêtre et bascules de `Nav` (une seule fois par fenêtre).
    static func watch(_ w: NSWindow) {
        guard on, observers.isEmpty else { return }
        note("fenêtre créée \(describe(w.frame)) \(describe(w.screen))")
        let names: [Notification.Name] = [NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification,
                                          NSWindow.didChangeBackingPropertiesNotification, NSWindow.didMoveNotification,
                                          NSWindow.didResizeNotification, NSWindow.willMoveNotification, NSWindow.didChangeScreenProfileNotification,
                                          NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
        for n in names {
            observers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak w] note in
                MainActor.assumeIsolated {
                    guard let w else { return }
                    let name = note.name.rawValue.replacingOccurrences(of: "NSWindow", with: "").replacingOccurrences(of: "Notification", with: "")
                    Self.note("· \(name) \(describe(w.frame)) \(describe(w.screen)) occlusion=\(w.occlusionState.contains(.visible) ? "visible" : "cachée")")
                }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak w] _ in
            MainActor.assumeIsolated { Self.note("· espace actif changé \(w.map { describe($0.frame) } ?? "")") }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.note("· écrans changés : \(NSScreen.screens.map { describe($0) }.joined(separator: " | "))") }
        })
        Task { @MainActor in for await v in Observed.values({ Nav.shared.visible }) { note("Nav.visible = \(v)") } }
        Task { @MainActor in for await v in Observed.values({ Nav.shared.live }) { note("Nav.live = \(v)") } }
    }
}

/// Fenêtre principale en mode `--log-window-frames` : identique à `NSWindow`, chaque appel qui peut déplacer ou redimensionner la fenêtre est noté.
final class LoggedWindow: ShellWindow {
    override func setFrame(_ r: NSRect, display: Bool) {
        WindowLog.note("setFrame \(WindowLog.describe(frame)) → \(WindowLog.describe(r))", stack: true)
        super.setFrame(r, display: display)
    }
    override func setFrame(_ r: NSRect, display: Bool, animate: Bool) {
        WindowLog.note("setFrame(animate:\(animate)) \(WindowLog.describe(frame)) → \(WindowLog.describe(r))", stack: true)
        super.setFrame(r, display: display, animate: animate)
    }
    override func setFrameOrigin(_ p: NSPoint) {
        WindowLog.note("setFrameOrigin \(WindowLog.describe(frame)) → (\(Int(p.x)), \(Int(p.y)))", stack: true)
        super.setFrameOrigin(p)
    }
    override func setFrameTopLeftPoint(_ p: NSPoint) {
        WindowLog.note("setFrameTopLeftPoint → (\(Int(p.x)), \(Int(p.y)))", stack: true)
        super.setFrameTopLeftPoint(p)
    }
    override func setContentSize(_ s: NSSize) {
        WindowLog.note("setContentSize \(Int(s.width))×\(Int(s.height))", stack: true)
        super.setContentSize(s)
    }
    override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect {
        let c = super.constrainFrameRect(r, to: screen)
        WindowLog.note("constrainFrameRect \(WindowLog.describe(r)) → \(WindowLog.describe(c)) \(WindowLog.describe(screen))", stack: c != r)
        return c
    }
    override func center() {
        WindowLog.note("center", stack: true)
        super.center()
    }
    override func orderFront(_ sender: Any?) {
        WindowLog.note("orderFront", stack: true)
        super.orderFront(sender)
    }
    override func makeKey() {
        WindowLog.note("makeKey", stack: true)
        super.makeKey()
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        WindowLog.note("makeKeyAndOrderFront", stack: true)
        super.makeKeyAndOrderFront(sender)
    }
}

/// `--dump-menus` (jamais en fonctionnement normal) : la barre des menus de zerOS, avec les raccourcis, dans `FS.support/menus.txt`
/// (contrôle des raccourcis standard et de la langue des menus fournis par macOS).
@MainActor
enum MenuDump {
    static func run() {
        guard CommandLine.arguments.contains("--dump-menus") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            var out = ""
            func walk(_ m: NSMenu, _ depth: Int) {
                for i in m.items where !i.isSeparatorItem {
                    m.delegate?.menuNeedsUpdate?(m)
                    var key = ""
                    if !i.keyEquivalent.isEmpty {
                        let f = i.keyEquivalentModifierMask
                        key = (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "") + i.keyEquivalent
                    }
                    out += String(repeating: "  ", count: depth) + i.title + (key.isEmpty ? "" : "  [\(key)]") + (i.isHidden ? "  (caché)" : "") + "\n"
                    if let s = i.submenu, depth < 2 { walk(s, depth + 1) }
                }
            }
            if let m = NSApp.mainMenu { walk(m, 0) }
            try? out.write(to: FS.support.appendingPathComponent("menus.txt"), atomically: true, encoding: .utf8)
        }
    }
}
