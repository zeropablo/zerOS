import SwiftUI
import AppKit

/// Mouvement (DESIGN.md §11) : trois niveaux, un seul endroit. Un rebond = un seul dépassement net puis l'arrêt, jamais plusieurs
/// oscillations ; un seul élément rebondit à la fois (la bulle de sélection) ; le contenu des pages ne rebondit jamais (`.smooth`).
/// Toutes sont des animations SwiftUI synchronisées à l'écran (120 Hz) : aucune n'est pilotée par une minuterie. Interrompues,
/// elles repartent de leur position et de leur vitesse du moment (ressorts natifs).
/// « Réduire les animations » : tous les niveaux deviennent un fondu court, sans rebond. Aucune animation codée en dur ailleurs.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || A11ySim.reduceMotion }

    /// Fondu court (réduire les animations).
    static let shortFade: Animation = .easeOut(duration: 0.12)

    /// Ressorts des niveaux (aussi lus par l'autotest, qui suit la bulle image par image).
    static let sectionSpring = Spring.bouncy(duration: 0.4, extraBounce: 0.05)
    static let subsectionSpring = Spring.snappy(duration: 0.3, extraBounce: 0.08)

    /// Niveau 1 : bulle de sélection du rail (changement de section). Un dépassement net.
    static var section: Animation { reduced ? shortFade : .bouncy(duration: 0.4, extraBounce: 0.05) }
    /// Niveau 2 : bulle de la capsule de sous-sections. Un petit dépassement.
    static var subsection: Animation { reduced ? shortFade : .snappy(duration: 0.3, extraBounce: 0.08) }
    /// Niveau 3 : filtres, tri, listes, cases, recherche, chiffres, survol. Aucun dépassement.
    static var detail: Animation { reduced ? shortFade : .smooth(duration: 0.25) }
    /// Contenu des pages (apparitions, métamorphoses, panneaux, résultats, arborescence) : toujours sans rebond.
    static var content: Animation { reduced ? shortFade : .smooth(duration: 0.3) }

    enum Level { case subsection, detail }
    /// Métamorphose du contenu (fondu croisé, flou) : 0,3 s en sous-section, 0,25 s en détail, sans rebond.
    static func morph(_ l: Level) -> Animation { l == .subsection ? content : detail }

    /// Fondu croisé des fonds et des pages au changement de section (0,35 s), sans rebond.
    static var background: Animation { reduced ? shortFade : .smooth(duration: 0.35) }
    static var pageFade: TimeInterval { reduced ? 0.12 : 0.35 }

    /// Fondu d'une petite fenêtre (bulle sous l'icône de la barre des menus), en secondes.
    static var windowIn: TimeInterval { reduced ? 0.12 : 0.2 }
    static var windowOut: TimeInterval { reduced ? 0.12 : 0.25 }
}

/// Réglages d'accessibilité simulés pour les captures (`--simulate-reduce-motion`, `--simulate-reduce-transparency`,
/// `--simulate-increase-contrast`), sans toucher aux réglages du Mac. Ils passent par les mêmes chemins que les vrais réglages (`Motion.reduced`,
/// `opaqueSurfaces`, environnement SwiftUI) ; le verre natif de macOS 26 et les matériaux système, eux, ne suivent que le vrai réglage.
enum A11ySim {
    static let reduceMotion = CommandLine.arguments.contains("--simulate-reduce-motion")
    static let reduceTransparency = CommandLine.arguments.contains("--simulate-reduce-transparency")
    static let increaseContrast = CommandLine.arguments.contains("--simulate-increase-contrast")
}

/// Surfaces opaques : « Réduire la transparence » ou « Augmenter le contraste ». Le verre et les panneaux du thème deviennent un fond
/// opaque lisible (le texte blanc sur photo floutée n'a pas un contraste garanti). Valeur par défaut lue sur le Mac (vues hors d'une
/// racine), tenue à jour par `accessibilityRoot()` à la racine de chaque vue hôte (fenêtre, pages, panneau).
private struct OpaqueSurfacesKey: EnvironmentKey {
    static var defaultValue: Bool {
        let w = NSWorkspace.shared
        return w.accessibilityDisplayShouldReduceTransparency || w.accessibilityDisplayShouldIncreaseContrast || A11ySim.reduceTransparency || A11ySim.increaseContrast
    }
}
extension EnvironmentValues {
    var opaqueSurfaces: Bool { get { self[OpaqueSurfacesKey.self] } set { self[OpaqueSurfacesKey.self] = newValue } }
}

private struct AccessibilityRoot: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var transparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .transformEnvironment(\._accessibilityReduceMotion) { if A11ySim.reduceMotion { $0 = true } }
            .transformEnvironment(\._accessibilityReduceTransparency) { if A11ySim.reduceTransparency { $0 = true } }
            .transformEnvironment(\._colorSchemeContrast) { if A11ySim.increaseContrast { $0 = .increased } }
            .environment(\.opaqueSurfaces, transparency || contrast == .increased || A11ySim.reduceTransparency || A11ySim.increaseContrast)
    }
}
extension View {
    /// À la racine de chaque vue hôte : réglages d'accessibilité (vrais ou simulés) lus une fois pour toutes les vues dessous.
    func accessibilityRoot() -> some View { modifier(AccessibilityRoot()) }
}

/// Rayons des « bulles de verre » (DESIGN.md §8) : aucun angle vif.
enum Radius {
    /// Panneaux de contenu, barres flottantes.
    static let panel: CGFloat = 26
    /// Zone de contenu de la fenêtre.
    static let content: CGFloat = 28
    /// Lignes de listes et de tableaux.
    static let row: CGFloat = 12
    /// Petites fenêtres (bulle de la barre des menus, panneau).
    static let bubble: CGFloat = 20
    /// Rail de navigation.
    static let rail: CGFloat = 30
}

/// Un état de la métamorphose : opacité et flou. Pas d'échelle : une page qui change d'échelle oblige à remettre en page, image par image,
/// toutes ses listes AppKit (mesuré 0.9.9 : 35 % d'images perdues avec l'échelle, 12 % sans, flou gardé ou non).
struct MorphEffect: ViewModifier {
    let opacity: Double, blur: CGFloat
    func body(content: Content) -> some View { content.blur(radius: blur).opacity(opacity) }
}

extension AnyTransition {
    /// L'ancien contenu sort (opacité, flou 6 pt) pendant que le nouveau entre (flou → 0, opacité). Réduire les animations : fondu seul.
    @MainActor static var morph: AnyTransition {
        if Motion.reduced { return .opacity }
        return .modifier(active: MorphEffect(opacity: 0, blur: 6), identity: MorphEffect(opacity: 1, blur: 0))
    }
}

extension View {
    /// Métamorphose quand la clé change (section, sous-section, détail) : ancien et nouveau contenu en fondu croisé.
    func morph<K: Hashable>(key: K, _ level: Motion.Level) -> some View {
        ZStack { id(key).transition(.morph) }.animation(Motion.morph(level), value: key)
    }
}

/// Fin d'un changement de section (DESIGN.md §11) : pendant le fondu des pages, les blocs lourds ne montrent que leur structure
/// (capsules, panneaux à leur taille finale) ; leurs données se posent ensuite en `Motion.content`. Début et fin sont donnés par le
/// fondu lui-même (`PageDeck`), aucune minuterie.
@MainActor
final class Settle: ObservableObject {
    static let shared = Settle()
    @Published private(set) var ready = true
    private var pending: [@MainActor () -> Void] = []

    /// Données calculées hors du fil principal : posées seulement une fois la transition finie, en `Motion.content`.
    func whenReady(_ apply: @escaping @MainActor () -> Void) {
        if ready { withAnimation(Motion.content) { apply() } } else { pending.append(apply) }
    }

    private var waiting: [AppSection: [@MainActor () -> Void]] = [:]

    /// Données d'une page de section arrivées en arrière-plan : posées si elle est affichée (après la transition en cours), sinon gardées
    /// jusqu'à son retour à l'écran. Une page cachée ne refait rien (mesuré rc2 : 60 à 105 ms de mise en page au repos sur Aujourd'hui).
    func whenShown(_ s: AppSection, _ apply: @escaping @MainActor () -> Void) {
        if Nav.shared.section == s { whenReady(apply) } else { waiting[s, default: []].append(apply) }
    }

    /// Numéro de la dernière transition commencée : la fin d'une transition dépassée (clics rapides) ne libère rien.
    private var token = 0

    @discardableResult func begin() -> Int { ready = false; token += 1; return token }

    /// `t` : fin de la transition numéro `t`, ignorée si une autre a commencé depuis ; nil : fin sans condition.
    func end(_ t: Int? = nil) {
        if let t, t != token { return }
        ready = true
        let p = pending + (waiting.removeValue(forKey: Nav.shared.section) ?? []); pending = []
        if !p.isEmpty { withAnimation(Motion.content) { p.forEach { $0() } } }
    }

    /// Changement de sous-section ou d'onglet : pendant la métamorphose, la vue arrivante ne montre que sa structure (blocs `Deferred`
    /// vides, données en attente) ; le reste se construit à la fin de l'animation, donnée par SwiftUI (aucune minuterie).
    func transition(_ change: () -> Void) {
        let t = begin()
        withAnimation(Motion.content, completionCriteria: .logicallyComplete) { change() } completion: { Settle.shared.end(t) }
    }
}

/// N'observe pas `Settle` (un bloc déjà montré ne se refait pas à chaque changement de section) : il en reçoit seulement les valeurs.
struct Deferred<Content: View>: View {
    @Local private var shown = Settle.shared.ready
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            if shown { content().transition(.opacity) }
            else { Color.clear }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(Settle.shared.$ready) { r in if r && !shown { withAnimation(Motion.content) { shown = true } } }
    }
}

private struct PageStateKey: EnvironmentKey { nonisolated(unsafe) static let defaultValue: PageState? = nil }
extension EnvironmentValues {
    /// État de la page de section qui contient la vue (constant : seules les vues qui l'observent se refont quand la page se montre
    /// ou se cache ; une valeur d'environnement qui change, elle, faisait revérifier toute la page, ≈ 30 ms).
    var pageState: PageState? { get { self[PageStateKey.self] } set { self[PageStateKey.self] = newValue } }
    /// Même chose pour une sous-section gardée de `TabDeck` (nil = affichée).
    var tabState: PageState? { get { self[TabStateKey.self] } set { self[TabStateKey.self] = newValue } }
}
private struct TabStateKey: EnvironmentKey { nonisolated(unsafe) static let defaultValue: PageState? = nil }

/// Action lancée quand la page devient visible : à sa création si elle est affichée, et à chaque retour dans sa section.
private struct OnShow: ViewModifier {
    @Environment(\.pageState) private var page
    let action: () -> Void
    var hide: (() -> Void)?
    func body(content: Content) -> some View {
        content.background { ShowWatcher(state: page ?? .always, action: action, hide: hide) }
    }
}

private struct ShowWatcher: View {
    @ObservedObject var state: PageState
    let action: () -> Void
    let hide: (() -> Void)?
    var body: some View {
        Color.clear
            .onAppear { if state.shown { action() } }
            .onChange(of: state.shown) { _, s in if s { action() } else { hide?() } }
            .onDisappear { hide?() }
    }
}

extension View {
    func onShow(_ action: @escaping () -> Void) -> some View { modifier(OnShow(action: action)) }
    /// Même chose, avec une action quand la page se cache ou disparaît (fenêtre fermée) : à rendre idempotente.
    func onShow(_ action: @escaping () -> Void, hide: @escaping () -> Void) -> some View { modifier(OnShow(action: action, hide: hide)) }
}
