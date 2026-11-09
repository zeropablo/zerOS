import Foundation
import SystemConfiguration
import IOKit.ps

/// The Mac zerOS runs on, detected once at launch.
enum Machine {
    /// Computer name from Réglages Système > Général > Informations (e.g. "Mac mini de Camille").
    /// Captures publiques : `--demo-machine-name=MacBook Pro` affiche un nom neutre (jamais en fonctionnement normal).
    static let name: String = CommandLine.arguments.first { $0.hasPrefix("--demo-machine-name=") }.map { String($0.dropFirst(20)) }
        ?? (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "ce Mac"

    /// Model identifier, e.g. "Mac16,10".
    static let model: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }()

    /// True on a MacBook: an internal battery is reported by the power sources.
    static let hasBattery: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { ps in
            let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any]
            return d?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()

    static var symbol: String { hasBattery ? "laptopcomputer" : "macmini" }
}
