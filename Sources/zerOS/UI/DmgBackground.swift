import SwiftUI
import AppKit

/// Fond de la fenêtre du .dmg (`--render-dmg-background DOSSIER`, mode outil appelé par make_dmg.sh, jamais en fonctionnement normal) :
/// fond d'Aujourd'hui recadré, voile clair léger sous les noms d'icônes, et une flèche en vrai verre natif (`.glassEffect`) posée sur le
/// fond, de l'icône de zerOS vers le raccourci Applications. Rendue dans une petite fenêtre sans bord ; l'app écrit son numéro de
/// fenêtre dans `DOSSIER/winid` une fois le verre posé, make_dmg.sh la capture en 2x (`screencapture -l`) puis ferme l'app.
@MainActor
enum DmgBackground {
    static let size = CGSize(width: 660, height: 420)
    /// Centres des icônes en points depuis le haut à gauche (mêmes valeurs dans make_dmg.sh).
    static let appIcon = CGPoint(x: 165, y: 170), applications = CGPoint(x: 495, y: 170), guide = CGPoint(x: 330, y: 300)

    static func run(_ dir: String) {
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: DmgBackgroundView())
        w.hasShadow = false
        w.level = .floating
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            try? "\(w.windowNumber)".write(toFile: dir + "/winid", atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(0) }
    }
}

/// Flèche aux coins arrondis : tige en capsule et pointe triangulaire, réunies en une seule forme (un seul verre).
struct DmgArrow: Shape {
    func path(in r: CGRect) -> Path {
        let shaft = r.height * 0.34, head = r.height * 0.85
        var tail = Path(roundedRect: CGRect(x: r.minX, y: r.midY - shaft / 2, width: r.width - head * 0.6, height: shaft), cornerRadius: shaft / 2)
        var tip = Path()
        let a = CGPoint(x: r.maxX - head, y: r.minY), b = CGPoint(x: r.maxX, y: r.midY), c = CGPoint(x: r.maxX - head, y: r.maxY)
        tip.move(to: CGPoint(x: a.x, y: r.midY))
        tip.addArc(tangent1End: a, tangent2End: b, radius: 7)
        tip.addArc(tangent1End: b, tangent2End: c, radius: 7)
        tip.addArc(tangent1End: c, tangent2End: a, radius: 7)
        tip.closeSubpath()
        tail = tail.union(tip)
        return tail
    }
}

struct DmgBackgroundView: View {
    var body: some View {
        let s = DmgBackground.size
        ZStack(alignment: .topLeading) {
            if let u = ThemePack.shared.root?.appendingPathComponent("aujourdhui/background.jpg"), let img = NSImage(contentsOf: u) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: s.width, height: s.height).clipped()
            } else {
                LinearGradient(colors: [Palette.skyDeep, Palette.aqua], startPoint: .top, endPoint: .bottom)
            }
            // Voile sous les noms d'icônes : le Finder les écrit en noir sur une image de fond (constaté, même en mode sombre), le voile
            // est donc clair.
            ForEach([DmgBackground.appIcon, DmgBackground.applications, DmgBackground.guide], id: \.x) { p in
                Capsule().fill(Color.white.opacity(0.4)).frame(width: 180, height: 26).blur(radius: 12)
                    .position(x: p.x, y: p.y + 87)
            }
            let from = DmgBackground.appIcon.x + 84, to = DmgBackground.applications.x - 84
            Color.clear
                .frame(width: to - from, height: 60)
                .glassSurface(.regular.tint(Palette.aqua.opacity(0.3)), in: DmgArrow())
                .overlay(DmgArrow().stroke(Color.white.opacity(0.45), lineWidth: 1))
                .shadow(color: Palette.nightBlue.opacity(0.35), radius: 8, y: 3)
                .position(x: (from + to) / 2, y: DmgBackground.appIcon.y)
        }
        .frame(width: s.width, height: s.height)
        .ignoresSafeArea()
    }
}
