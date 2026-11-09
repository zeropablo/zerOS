import SwiftUI
import AppKit

/// Panneau de la barre des menus (SPEC.md) : les états clés d'Aujourd'hui (disque, mémoire, disques externes) avec les
/// mêmes seuils et couleurs, puis des raccourcis vers les six sections. Le détail se déplie au clic ; rien ne tourne quand il est fermé.
struct MenuPanel: View {
    let m = SystemMonitor.shared
    @Local private var expanded: String?

    var snapshot: TodaySnapshot {
        var s = TodaySnapshot(diskFree: m.diskFree, diskTotal: m.diskTotal, pressure: m.pressure, swapUsed: m.swapUsed, memTotal: m.memTotal,
                              externals: m.devices.filter { $0.kind == "drive" && $0.external && !$0.readOnly && $0.total > 0 }, trashSize: m.trashSize)
        return s
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            VStack(spacing: 8) {
                ForEach(TodayEngine.states(snapshot)) { st in state(st) }
                shortcuts
            }
            footer
        }
        .padding(14)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    func openMain(_ section: AppSection? = nil) {
        StatusBar.shared.close()
        if let section { Router.shared.section = section }
        MainWindow.shared.show()
    }

    var header: some View {
        HStack(spacing: 12) {
            Text(Machine.name).font(Typo.headline).lineLimit(1)
            Spacer()
            Text("Allumé depuis \(Fmt.uptime(m.uptime))").font(Typo.caption).foregroundStyle(.secondary)
        }
    }

    func levelColor(_ l: Level) -> Color { l == .green ? .green : (l == .orange ? .orange : .red) }

    /// Un état : pastille de couleur, chiffre clé ; clic = détail ; bouton = la section.
    func state(_ st: TodayState) -> some View {
        let id = String(describing: st.kind)
        return VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(Motion.content) { expanded = expanded == id ? nil : id } } label: {
                HStack(spacing: 10) {
                    Circle().fill(levelColor(st.level)).frame(width: 10, height: 10)
                    Text(st.title).fontWeight(.medium)
                    Spacer()
                    Text(st.value).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    Image(systemName: "chevron.right").font(Typo.caption).foregroundStyle(.secondary).rotationEffect(.degrees(expanded == id ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded == id {
                VStack(alignment: .leading, spacing: 5) {
                    Text(st.detail).foregroundStyle(.secondary)
                    detail(st.kind)
                    HStack { Spacer(); Button("Ouvrir \(AppSection.containing(st.target).title)") { openMain(AppSection.containing(st.target)) } }.controlSize(.small)
                }
                .font(Typo.detail)
            }
        }
        .padding(10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }

    @ViewBuilder func detail(_ kind: TodayState.Kind) -> some View {
        switch kind {
        case .disk:
            row("Libre immédiatement", Fmt.bytes(m.diskFreeStrict))
            row("Corbeille", Fmt.bytes(m.trashSize))
            Button("Vider la corbeille…") { StatusBar.shared.close(); Router.shared.go(.cleanup, tab: "trash") }.disabled(m.trashSize == 0).controlSize(.small)
        case .memory:
            row("Apps", Fmt.mem(m.memApp))
            row("Système (réservée)", Fmt.mem(m.memWired))
            row("Compressée", Fmt.mem(m.memCompressed))
            ForEach(m.topMem) { p in procRow(p, value: Fmt.mem(p.memory)) }
        case .externals:
            ForEach(m.devices.filter { $0.kind == "drive" && $0.external && !$0.readOnly }) { d in
                HStack {
                    Image(systemName: "externaldrive")
                    VStack(alignment: .leading, spacing: 0) { Text(d.name); Text(d.detail).font(Typo.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if let u = d.url {
                        Button { try? NSWorkspace.shared.unmountAndEjectDevice(at: u); m.refreshDevices() } label: { Image(systemName: "eject") }.buttonStyle(.borderless).help("Éjecter")
                    }
                }
            }
        }
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit() }
    }

    func procRow(_ p: ProcInfo, value: String) -> some View {
        HStack(spacing: 6) {
            Text(p.name).lineLimit(1)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
            Menu {
                Button("Quitter") { quit(p, force: false) }
                Button("Forcer à quitter", role: .destructive) { quit(p, force: true) }
            } label: { Image(systemName: "xmark.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    func quit(_ p: ProcInfo, force: Bool) {
        let apps = NSWorkspace.shared.runningApplications.filter { a in p.pids.contains(a.processIdentifier) }
        if !apps.isEmpty { for a in apps { if force { a.forceTerminate() } else { a.terminate() } } }
        else { p.pids.forEach { kill($0, force ? SIGKILL : SIGTERM) } }
    }

    /// Les six sections, dans l'ordre fixe.
    var shortcuts: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(Nav.shared.visibleSections) { s in
                Button { openMain(s) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: s.symbol).font(Typo.sectionTitle)
                        Text(s.title).font(Typo.caption)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            }
        }
    }

    var footer: some View {
        HStack {
            Button("Ouvrir zerOS") { openMain() }
            Spacer()
            Button { StatusBar.shared.close(); NSApp.activate(ignoringOtherApps: true); NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) } label: { Image(systemName: "gearshape") }.buttonStyle(.borderless)
            Button("Quitter") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
}
