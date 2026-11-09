import Observation

/// Équivalent de `Observations` (macOS 26) pour macOS 15 : valeur actuelle, puis chaque nouvelle valeur (une observation relancée à
/// chaque changement avec `withObservationTracking`). Sur macOS 26 et plus, les appelants gardent `Observations`.
@MainActor
enum Observed {
    static func values<T>(_ read: @escaping @MainActor () -> T) -> AsyncStream<T> {
        AsyncStream { c in
            @MainActor func next() {
                c.yield(withObservationTracking(read) { Task { @MainActor in next() } })
            }
            next()
        }
    }
}
