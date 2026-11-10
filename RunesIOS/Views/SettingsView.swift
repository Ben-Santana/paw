import SwiftUI

struct SettingsValues {
    var bandSetUp = true
    var battery: Int?
    var hand: Handedness?
    var macs: [MacLinks.Mac] = []
    var macPairing: MacLinks.Pairing = .idle
    var version = "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"))"
}

struct SettingsActions {
    var forget: () -> Void = {}
    var batteryAlertsChanged: (Bool) -> Void = { _ in }
    /// Takes the scanned code; returns an error message if it isn't a Mac code.
    var pairMac: (String) -> String? = { _ in nil }
    var removeMac: (UUID) -> Void = { _ in }
    var done: () -> Void = {}
}

/// Value-driven settings. `advanced` is supplied by the caller so previews can stub it.
struct SettingsView<Advanced: View>: View {
    let values: SettingsValues
    var actions = SettingsActions()
    @ViewBuilder var advanced: () -> Advanced
    @AppStorage(Preferences.haptics) private var haptics = true
    @AppStorage(Preferences.batteryAlerts) private var batteryAlerts = false
    @State private var confirmForget = false
    @State private var scanningMac = false
    @State private var macToRemove: MacLinks.Mac?
    @State private var scanProblem: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    PanelGroup("Band") {
                        ValueRow("Battery") { Text(values.battery.map { "\($0)%" } ?? "—").monospacedDigit() }
                        Rule()
                        ValueRow("Hand") { Text(values.hand.map { $0 == .left ? "Left" : "Right" } ?? "—") }
                        Rule()
                        ActionRow("Forget band") { confirmForget = true }.disabled(!values.bandSetUp)
                    }
                    PanelGroup("Mac") {
                        ForEach(values.macs) { mac in
                            Button { macToRemove = mac } label: {
                                HStack {
                                    Text(mac.name).font(.bodyText)
                                    Spacer()
                                    Text(mac.state == .connected ? "Connected" : mac.statusText.replacingOccurrences(of: mac.name, with: "Mac"))
                                        .font(.bodyText).foregroundStyle(Color.muted).lineLimit(1)
                                }
                                .panelRow()
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows the option to remove this Mac")
                            .swipeToDelete(confirms: true) { macToRemove = mac }
                            Rule()
                        }
                        ActionRow(values.macs.isEmpty ? "Pair Mac" : "Pair another Mac", icon: .qrCode) { scanProblem = nil; scanningMac = true }
                        if let progress = pairingText {
                            Rule()
                            Text(progress).font(.caption).foregroundStyle(Color.muted)
                                .padding(.horizontal, Metric.inset).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    PanelGroup("Preferences") {
                        Toggle(isOn: $haptics) { label("Haptics on gesture", "A light tap when a gesture arrives while Runes is open.") }
                            .padding(.horizontal, Metric.inset).padding(.vertical, 10)
                        Rule()
                        Toggle(isOn: $batteryAlerts) { label("Band battery alerts", "A notification when the band drops to 20%.") }
                            .padding(.horizontal, Metric.inset).padding(.vertical, 10)
                            .onChange(of: batteryAlerts) { _, on in actions.batteryAlertsChanged(on) }
                    }
                    PanelGroup("About") {
                        ValueRow("Version") { Text(values.version).monospacedDigit() }
                        Rule()
                        LinkRow("Privacy") { PrivacyView() }
                        Rule()
                        LinkRow("Licenses") { LicensesView() }
                    }
                    PanelGroup(nil) {
                        LinkRow("Motion lab") { MotionLabScreen() }
                        Rule()
                        LinkRow("Advanced") { advanced() }
                    }
                }
                .padding(Metric.gutter)
            }
            .page()
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { BackToolbarItem(action: actions.done) }
            .sheet(isPresented: $scanningMac) {
                IdentityScanner(title: "Scan the code on your Mac") { text in scanProblem = actions.pairMac(text) }
            }
            .confirmationDialog(macToRemove.map { "Remove \($0.name)?" } ?? "", isPresented: Binding(get: { macToRemove != nil }, set: { if !$0 { macToRemove = nil } }), titleVisibility: .visible, presenting: macToRemove) { mac in
                Button("Remove Mac", role: .destructive) { actions.removeMac(mac.id) }
            } message: { _ in
                Text("This Mac stops receiving your gestures until you pair it again.")
            }
            .confirmationDialog("Forget this band?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget band", role: .destructive, action: actions.forget)
            } message: {
                Text("Runes disconnects and you’ll set the band up again. Your Meta sign-in stays saved on this phone.")
            }
        }
        .tint(Color.ink)
    }

    private var pairingText: String? {
        if let scanProblem { return scanProblem }
        switch values.macPairing {
        case .idle: return values.macs.isEmpty ? "On your Mac, open Runes to show its pairing code." : nil
        case .searching(let name): return "Looking for \(name)… Keep Runes open on the Mac."
        case .confirming(let name): return "Pairing with \(name)… Accept the Bluetooth request if one appears."
        case .paired(let name): return "Paired with \(name)."
        case .failed(let message): return message
        }
    }

    private func label(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.bodyText)
            Text(detail).font(.caption).foregroundStyle(Color.muted)
        }
    }

}

/// Live settings sheet.
struct SettingsScreen: View {
    @ObservedObject var controller: SessionController
    @ObservedObject private var links = MacLinks.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SettingsView(values: SettingsValues(bandSetUp: controller.snapshot.selected != nil,
                                            battery: controller.snapshot.battery, hand: controller.snapshot.hand,
                                            macs: links.macs, macPairing: links.pairing),
                     actions: SettingsActions(
                        forget: { controller.forgetBand(); dismiss() },
                        batteryAlertsChanged: { on in if on { Task { _ = await BatteryAlerts.requestPermission() } } },
                        pairMac: { text in
                            do { try links.pair(text); return nil }
                            catch { return (error as? LocalizedError)?.errorDescription ?? "That isn’t a Mac pairing code." }
                        },
                        removeMac: { links.remove($0) },
                        done: { dismiss() })) {
            AdvancedScreen(controller: controller)
        }
    }
}

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paragraph("Your gestures stay on your phone.", "Runes receives gestures from your band over Bluetooth. Nothing is sent to the developer or to analytics services.")
                paragraph("Meta sign-in happens once.", "Signing in links this phone to your band. It runs in a private browser window that keeps no cookies, and Runes stores only the band key it needs, in this phone’s Keychain.")
                paragraph("Your Mac, if you pair one.", "A paired Mac receives your gestures directly from this phone over Bluetooth.")
                paragraph("A local journal helps fix problems.", "Runes keeps up to 4 MB of connection events and gestures on this phone, excluded from backups. It leaves the phone only if you export it from Settings → Advanced.")
            }
            .padding(Metric.gutter)
        }
        .page()
        .navigationTitle("Privacy").navigationBarTitleDisplayMode(.inline)
    }
    private func paragraph(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.label)
            Text(body).font(.bodyText).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LicensesView: View {
    private var ofl: String {
        Bundle.main.url(forResource: "OFL", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "SIL Open Font License 1.1"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Runes’s band connection is a Swift port of meta-neural-py 0.1.0a1. It is not an official Meta product.")
                    .font(.bodyText).foregroundStyle(Color.muted)
                Text("Icons from Lucide (lucide.dev), used under the ISC License. Copyright © Lucide Contributors.")
                    .font(.bodyText).foregroundStyle(Color.muted)
                Text("Geist").font(.label)
                Text(ofl).font(.caption).foregroundStyle(Color.muted).textSelection(.enabled)
            }
            .padding(Metric.gutter)
        }
        .page()
        .navigationTitle("Licenses").navigationBarTitleDisplayMode(.inline)
    }
}
