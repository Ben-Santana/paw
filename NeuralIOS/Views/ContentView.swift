import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: SessionController
    @State private var confirmEnrollment = false
    @State private var importBand: UUID?
    @State private var showIdentityScanner = false
    @State private var showRelayScanner = false
    private var state: SessionSnapshot { controller.snapshot }
    var body: some View {
        NavigationStack {
            List {
                sessionSection
                connectionSection
                identitySection
                latestGestureSection
                recentEventsSection
                diagnosticsSection
            }
            .navigationTitle("Neural")
            .confirmationDialog("Enroll this phone?", isPresented: $confirmEnrollment, titleVisibility: .visible) {
                Button("Sign in and enroll", action: controller.enroll)
            } message: {
                Text("Enrollment changes the band's ownership identity and may require signing in again in the Mac app. If Meta omits the band public key, Neural uses compatibility mode: the connection is encrypted, but the band identity cannot be verified. Interrupted enrollment is retained securely for recovery.")
            }
            .sheet(item: Binding(get: { controller.loginRequest }, set: { if $0 == nil { controller.loginSheetDismissed() } }), onDismiss: controller.loginSheetDismissed) { request in
                NavigationStack {
                    MetaLoginView(request: request, completed: controller.loginCallback, failed: controller.loginFailed)
                        .navigationTitle("Meta sign-in").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: controller.cancelSignIn) } }
                }
            }
            .sheet(isPresented: $showIdentityScanner) {
                IdentityScanner { text in
                    if let id = importBand { controller.importIdentityQR(text, for: id) }
                    importBand = nil
                }
            }
            .sheet(isPresented: $showRelayScanner) {
                IdentityScanner(title: "Scan Mac test QR", completed: controller.pairRelay)
            }
            .alert("Neural", isPresented: Binding(get: { controller.uiError != nil }, set: { if !$0 { controller.uiError = nil } })) {
                Button("OK", role: .cancel) { controller.uiError = nil }
            } message: { Text(controller.uiError ?? "") }
        }
    }
    private var sessionSection: some View {
                Section {
                    HStack {
                        Image(systemName: state.state == .streaming ? "waveform" : "circle.dotted")
                            .foregroundStyle(state.state == .streaming ? Color.green : Color.secondary)
                        Text(state.state.title).font(.headline)
                        Spacer()
                        if [.disconnecting, .connecting, .authenticating, .subscribing, .enrolling, .reconnecting, .scanning].contains(state.state) { ProgressView() }
                    }
                    Text(state.message).foregroundStyle(.secondary)
                    if let error = state.journalError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    if let message = controller.activityMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Band session") }

    }

    private var connectionSection: some View {
                Section {
                    ForEach(state.devices) { device in
                        Button { controller.select(device) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name).foregroundStyle(.primary)
                                    Text(device.id.uuidString).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if device.id == state.selected { Image(systemName: "checkmark").foregroundStyle(.primary) }
                            }
                        }.disabled(state.wantsConnection || controller.isSigningIn || state.state == .disconnecting)
                    }
                    if let selected = state.selected, !state.devices.contains(where: { $0.id == selected }) {
                        Label("Saved band", systemImage: "applewatch").accessibilityValue(selected.uuidString)
                    }
                    Button("Scan for bands", systemImage: "antenna.radiowaves.left.and.right", action: controller.scan)
                        .disabled(state.wantsConnection || controller.isSigningIn || state.state == .disconnecting || state.state == .scanning)
                    if state.state == .scanning {
                        Button("Cancel scan", systemImage: "xmark", action: controller.disconnect)
                    }
                    if state.wantsConnection {
                        Button("Disconnect", systemImage: "xmark.circle", role: .destructive, action: controller.disconnect)
                    } else {
                        Button("Connect", systemImage: "link", action: { controller.connect() })
                            .disabled(state.selected == nil || controller.isSigningIn || state.state == .disconnecting)
                        if state.state == .failed {
                            Button("Retry Bluetooth release", action: controller.disconnect)
                                .disabled(controller.isSigningIn)
                        }
                    }
                    Button("Import Mac identity", systemImage: "qrcode.viewfinder") {
                        importBand = state.selected; showIdentityScanner = true
                    }.disabled(state.selected == nil || state.wantsConnection || controller.isSigningIn || state.state == .disconnecting)
                    Button(controller.isSigningIn ? "Cancel Meta sign-in" : "Sign in with Meta / enroll phone", systemImage: "person.crop.circle") {
                        if controller.isSigningIn { controller.cancelSignIn() } else { confirmEnrollment = true }
                    }.disabled(state.selected == nil || state.state == .disconnecting)
                } header: { Text("Connection") } footer: {
                    Text("Disconnect on Mac and wait for local cleanup before connecting here. If the band has a new Bluetooth ID, choose its existing ownership identity below. Pairing mode and ownership enrollment are separate operations.")
                }

    }

    private var identitySection: some View {
        Section {
            if let fingerprint = state.identityFingerprint {
                LabeledContent("Selected host fingerprint") { Text(fingerprint).font(.caption).textSelection(.enabled) }
            }
            ForEach(state.identityChoices) { choice in
                Button {
                    controller.connect(account: choice.account, pending: choice.pending)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(choice.pending ? "Try pending identity" : "Use saved identity")
                        Text(choice.fingerprint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("\(choice.stage) · \(choice.hasBandKey ? "band proof available" : "compatibility; band unverified") · \(choice.account.uuidString.suffix(6))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(!choice.eligible || state.selected == nil || state.wantsConnection || controller.isSigningIn || state.state == .disconnecting)
            }
            Button("Refresh saved identities", action: controller.refreshIdentities)
                .disabled(state.wantsConnection || controller.isSigningIn || state.state == .disconnecting)
        } header: { Text("Ownership identity") } footer: {
            Text("Compare this public fingerprint with Mac. Choosing an existing identity connects without enrollment and preserves other records. A pending candidate replaces the saved identity only after authentication. In compatibility mode, successful host authentication cannot verify the band's identity; select the same physical band yourself.")
        }
    }

    private var latestGestureSection: some View {
                Section {
                    if let event = state.events.first {
                        Text(event.title).font(.title3).fontWeight(.medium)
                        if event.derivedActionCode != 0 { Text(event.derivedAction).foregroundStyle(.secondary) }
                        Text(event.received.wallTime, style: .time).font(.caption).foregroundStyle(.secondary)
                    } else { Text("Waiting for your first gesture.").foregroundStyle(.secondary) }
                    LabeledContent("Events received", value: state.eventCount.formatted())
                } header: { Text("Latest gesture") }

    }

    private var recentEventsSection: some View {
                Section("Recent events") {
                    ForEach(state.events) { event in
                        NavigationLink {
                            GestureDetail(event: event)
                        } label: {
                            GestureEventRow(event: event)
                        }
                    }
                    if state.events.isEmpty { Text("Gesture events will appear here.").foregroundStyle(.secondary) }
                }

    }

    private var diagnosticsSection: some View {
                Section {
                    NavigationLink { DiagnosticsView(controller: controller) } label: {
                        Label("Diagnostics", systemImage: "list.bullet.rectangle")
                    }
                    Text(controller.relayStatus).foregroundStyle(.secondary)
                    Button("Pair Mac BLE test receiver", systemImage: "qrcode.viewfinder") {
                        showRelayScanner = true
                    }
                }
    }

}

private struct GestureEventRow: View {
    let event: GestureEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.title)
            HStack {
                Text(event.layer)
                Spacer()
                Text(event.received.wallTime, style: .time)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct GestureDetail: View {
    let event: GestureEvent
    var body: some View {
        List {
            Section("Gesture") {
                LabeledContent("Finger", value: "\(event.finger) (\(event.fingerCode))")
                LabeledContent("Raw", value: "\(event.action) (\(event.actionCode))")
                LabeledContent("Derived", value: "\(event.derivedAction) (\(event.derivedActionCode))")
                LabeledContent("Synthetic", value: event.synthetic ? "Yes" : "No")
                LabeledContent("Sequence", value: String(event.sequence))
            }
            Section("Receipt evidence") {
                LabeledContent("Device timestamp", value: String(event.deviceTimestamp))
                LabeledContent("Device clock", value: event.sourceClock)
                LabeledContent("Host uptime", value: String(format: "%.6f s", event.received.uptime))
                LabeledContent("Host time", value: event.received.wallTime.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
                LabeledContent("App state at callback", value: event.received.applicationState)
                Text("Device time and host time are separate clocks. Background state does not identify whether the display was dark.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Session") { Text(event.sessionID.uuidString).font(.caption).textSelection(.enabled) }
        }.navigationTitle("Gesture details").navigationBarTitleDisplayMode(.inline)
    }
}

struct DiagnosticsView: View {
    @ObservedObject var controller: SessionController
    @State private var exported: URL?
    @State private var exporting = false
    @State private var confirmClear = false
    var body: some View {
        List {
            Section("Live Activity") {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if controller.canRenewLiveActivity(at: context.date) {
                        Button("Renew Live Activity", action: controller.renewLiveActivity)
                    } else {
                        Text("Renewal is available near expiry during a band session.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let message = controller.activityMessage { Text(message).foregroundStyle(.secondary) }
            }
            Section("Session") {
                LabeledContent("Status", value: controller.snapshot.state.title)
                LabeledContent("Events this app run", value: controller.snapshot.eventCount.formatted())
                if let date = controller.snapshot.startedAt { LabeledContent("Streaming since") { Text(date, style: .time) } }
                if let id = controller.snapshot.selected { Text(id.uuidString).font(.caption).textSelection(.enabled) }
            }
            Section {
                Button(exporting ? "Preparing export…" : "Export event journal") {
                    exporting = true
                    Task { exported = await controller.exportJournal(); exporting = false }
                }.disabled(exporting)
                if let exported { ShareLink("Share journal", item: exported) }
                Button("Clear journal and recent events", role: .destructive) { confirmClear = true }
                if let error = controller.snapshot.journalError { Text(error).foregroundStyle(.orange) }
            } header: { Text("Local evidence") } footer: {
                Text("The journal retains up to 4 MiB of callback-time events, lifecycle transitions, and connection errors. A full journal rotates the oldest segment. Exported events contain gesture data and device identifiers; secrets are excluded.")
            }
            Section("Background verification") {
                Text("Use a standalone Release build with the debugger disconnected. Perform gestures in another app, on the Lock Screen, and after the screen has stayed dark for 1, 5, and 15 minutes.")
                Text("Export the journal and compare host receipt times with those intervals. A burst received after reopening is not evidence of screen-off processing.")
                Text("Repeat with the Live Activity active and dismissed. iOS controls background execution; powered-off operation and recovery after force-quit are not guaranteed.")
            }.font(.footnote)
        }
        .navigationTitle("Diagnostics")
        .confirmationDialog("Clear local gesture history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear journal", role: .destructive) { controller.clearJournal(); exported = nil }
        }
    }
}
