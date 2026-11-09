import Foundation
import AppKit

/// Actions that need more than "delete this file": empty an Adobe cache folder (regenerable), evict cloud files (kept online).
/// Vider la Corbeille n'est pas ici : action séparée (`TrashBins.empty`, `TrashPanel`). Les versions de documents sont en analyse seule.
enum CustomActions {
    struct Result { var ok: Bool; var freed: Int64; var error: String? }

    static func run(_ it: CleanItem) async -> Result {
        guard case .custom(let key) = it.mode else { return Result(ok: false, freed: 0, error: nil) }
        // Cloud copies of a protected file are never touched.
        // Adobe cache folders read from the preferences: their own checks (`CacheScan.prefsCacheBlocker`), read-only volume allowed.
        if key != "prefsCache", let u = it.url, !Ignore.removable(u) { return Result(ok: false, freed: 0, error: "dossier protégé (lecture seule)") }
        switch key {

        case "prefsCache":
            guard let u = it.url else { break }
            let r = CacheScan.emptyPrefsCache(u)
            if let why = r.refused { return Result(ok: false, freed: 0, error: why) }
            return Result(ok: r.errors == 0, freed: r.freed, error: r.errors > 0 ? "\(r.errors) fichier(s) en cours d'utilisation, laissés en place" : nil)

        case "evict":
            guard let u = it.url else { break }
            let (ok, freed, err) = CloudCleanup.evict(u)
            return Result(ok: ok, freed: freed, error: err)

        default: break
        }
        return Result(ok: false, freed: 0, error: "Action inconnue")
    }
}
