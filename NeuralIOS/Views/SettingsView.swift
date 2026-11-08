import SwiftUI

struct SettingsValues {
    var bandSetUp = true
    var battery: Int?
    var hand: Handedness?
    var version = "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"))"
}

struct SettingsActions {
    var forget: () -> Void = {}
    var batteryAlertsChanged: (Bool) -> Void = { _ in }
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    group("Band") {
                        row("Battery") { Text(values.battery.map { "\($0)%" } ?? "—").foregroundStyle(Color.muted).monospacedDigit() }
                        divider
                        row("Hand") { Text(values.hand.map { $0 == .left ? "Left" : "Right" } ?? "—").foregroundStyle(Color.muted) }
                        divider
                        Button { confirmForget = true } label: {
                            Text("Forget band").font(.bodyText).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .padding(.horizontal, 14).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(!values.bandSetUp)
                    }
                    group("Preferences") {
                        Toggle(isOn: $haptics) { label("Haptics on gesture", "A light tap when a gesture arrives while Neural is open.") }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        divider
                        Toggle(isOn: $batteryAlerts) { label("Band battery alerts", "A notification when the band drops to 20%.") }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .onChange(of: batteryAlerts) { _, on in actions.batteryAlertsChanged(on) }
                    }
                    group("About") {
                        row("Version") { Text(values.version).foregroundStyle(Color.muted).monospacedDigit() }
                        divider
                        link("Privacy") { PrivacyView() }
                        divider
                        link("Licenses") { LicensesView() }
                    }
                    group(nil) { link("Advanced") { advanced() } }
                }
                .padding(Metric.gutter)
            }
            .page()
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: actions.done).font(.label) } }
            .confirmationDialog("Forget this band?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget band", role: .destructive, action: actions.forget)
            } message: {
                Text("Neural disconnects and you’ll set the band up again. Your Meta sign-in stays saved on this phone.")
            }
        }
        .tint(Color.ink)
    }

    private var divider: some View { Rectangle().fill(Color.rule).frame(height: Metric.hairline).padding(.leading, 14) }

    private func group<Content: View>(_ title: String?, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { SectionLabel(title).padding(.leading, 2) }
            VStack(spacing: 0, content: content).panel()
        }
    }

    private func label(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.bodyText)
            Text(detail).font(.caption).foregroundStyle(Color.muted)
        }
    }

    private func row<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        HStack { Text(title).font(.bodyText); Spacer(); value().font(.bodyText) }
            .padding(.horizontal, 14).frame(minHeight: 48)
            .accessibilityElement(children: .combine)
    }

    private func link<Destination: View>(_ title: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack {
                Text(title).font(.bodyText)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.muted)
            }
            .padding(.horizontal, 14).frame(minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Live settings sheet.
struct SettingsScreen: View {
    @ObservedObject var controller: SessionController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SettingsView(values: SettingsValues(bandSetUp: controller.snapshot.selected != nil,
                                            battery: controller.snapshot.battery, hand: controller.snapshot.hand),
                     actions: SettingsActions(
                        forget: { controller.forgetBand(); dismiss() },
                        batteryAlertsChanged: { on in if on { Task { _ = await BatteryAlerts.requestPermission() } } },
                        done: { dismiss() })) {
            AdvancedScreen(controller: controller)
        }
    }
}

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paragraph("Your gestures stay on your phone.", "Neural receives gestures from your band over Bluetooth. Nothing is sent to the developer or to analytics services.")
                paragraph("Meta sign-in happens once.", "Signing in links this phone to your band. It runs in a private browser window that keeps no cookies, and Neural stores only the band key it needs, in this phone’s Keychain.")
                paragraph("Your Mac, if you pair one.", "A paired Mac receives your gestures directly from this phone over Bluetooth.")
                paragraph("A local journal helps fix problems.", "Neural keeps up to 4 MB of connection events and gestures on this phone, excluded from backups. It leaves the phone only if you export it from Settings → Advanced.")
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
                Text("Neural’s band connection is a Swift port of meta-neural-py 0.1.0a1. It is not an official Meta product.")
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
