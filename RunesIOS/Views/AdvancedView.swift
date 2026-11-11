import SwiftUI

struct AdvancedValues {
    var relayStatus: String
    var events: [GestureEvent] = []
    var eventCount = 0
    var canImportMacSetup = false
    var canSetUpBandAgain = false
    var selectedBand: UUID?
    var journalProblem: String?
    var connectionAttempt = ConnectionAttempt()
}

struct AdvancedActions {
    var export: () async -> URL? = { nil }
    var clear: () -> Void = {}
    var pairMac: (String) -> Void = { _ in }
    var importMacSetup: (String) -> Void = { _ in }
    var setUpBandAgain: (UUID) -> Void = { _ in }
}

/// Diagnostics that used to sit on the main screen. Raw packet codes are allowed here;
/// identity detail is not, and stays in the exported journal.
struct AdvancedView: View {
    let values: AdvancedValues
    var actions = AdvancedActions()
    @State private var exported: URL?
    @State private var exporting = false
    @State private var confirmClear = false
    @State private var scanner: Scanner?
    private enum Scanner: Identifiable { case mac, identity; var id: Self { self } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ConnectionAttemptView(attempt: values.connectionAttempt)
                PanelGroup("Journal", caption: "Up to 4 MB of connection events and gestures, kept on this phone. Exports contain gesture data and device identifiers.") {
                    ActionRow(exporting ? "Preparing…" : "Export journal") {
                        exporting = true
                        Task { exported = await actions.export(); exporting = false }
                    }
                    .disabled(exporting)
                    if let exported {
                        Rule()
                        ShareLink(item: exported) {
                            HStack { Text("Share journal").font(.bodyText); Spacer(); LucideIcon(.share, size: 16).foregroundStyle(Color.muted) }.panelRow()
                        }
                        .buttonStyle(.plain)
                    }
                    Rule()
                    ActionRow("Clear journal") { confirmClear = true }
                    if let problem = values.journalProblem {
                        Rule()
                        Text(problem).font(.caption).foregroundStyle(Color.muted).padding(Metric.inset)
                    }
                }
                PanelGroup("Band setup") {
                    ActionRow("Use my Mac’s band setup") { scanner = .identity }.disabled(!values.canImportMacSetup)
                    Rule()
                    BandSetupAgainAction(band: values.selectedBand, enabled: values.canSetUpBandAgain, action: actions.setUpBandAgain)
                }
                PanelGroup("Raw packets", caption: "\(values.eventCount) received this session. Newest first, up to 200.") {
                    if values.events.isEmpty {
                        Text("Gesture packets will appear here.").font(.bodyText).foregroundStyle(Color.muted).panelRow()
                    }
                    ForEach(Array(values.events.prefix(200).enumerated()), id: \.element.id) { offset, event in
                        if offset > 0 { Rule() }
                        NavigationLink { GestureDetail(event: event) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title).font(.bodyText)
                                    Text("\(event.layer) · #\(event.sequence)").font(.caption).foregroundStyle(Color.muted)
                                }
                                Spacer()
                                Text(event.received.wallTime, style: .time).font(.caption).foregroundStyle(Color.muted).monospacedDigit()
                                Chevron()
                            }
                            .padding(.horizontal, Metric.inset).padding(.vertical, 8).frame(minHeight: Metric.rowTall).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(Metric.gutter)
        }
        .page()
        .navigationTitle("Advanced").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear the journal and recent packets?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear journal", role: .destructive) { actions.clear(); exported = nil }
        }
        .sheet(item: $scanner) { kind in
            switch kind {
            case .mac: IdentityScanner(title: "Scan Mac test code", completed: actions.pairMac)
            case .identity: IdentityScanner(title: "Scan the code on your Mac", completed: actions.importMacSetup)
            }
        }
    }

}

struct AdvancedScreen: View {
    @ObservedObject var controller: SessionController
    var setUpBandAgain: (UUID) -> Void
    var body: some View {
        let snapshot = controller.snapshot
        AdvancedView(values: AdvancedValues(relayStatus: controller.relayStatus, events: snapshot.events, eventCount: snapshot.eventCount,
                                            canImportMacSetup: snapshot.selected != nil && !snapshot.wantsConnection,
                                            canSetUpBandAgain: controller.canSetUpBandAgain,
                                            selectedBand: snapshot.selected,
                                            journalProblem: snapshot.journalError,
                                            connectionAttempt: snapshot.connectionAttempt),
                     actions: AdvancedActions(export: controller.exportJournal, clear: controller.clearJournal,
                                              pairMac: controller.pairRelay,
                                              importMacSetup: { text in if let id = snapshot.selected { controller.importIdentityQR(text, for: id) } },
                                              setUpBandAgain: setUpBandAgain))
    }
}

struct BandSetupAgainAction: View {
    var band: UUID?
    var enabled: Bool
    var action: (UUID) -> Void
    @State private var confirm = false
    @State private var confirmedBand: UUID?

    var body: some View {
        ActionRow("Set up band again") {
            guard enabled, let band else { return }
            confirmedBand = band; confirm = true
        }
            .disabled(!enabled)
            .confirmationDialog("Set up this band again?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Continue with Meta", role: .destructive) {
                    if enabled, let confirmedBand, band == confirmedBand { action(confirmedBand) }
                }
                .disabled(!enabled || band != confirmedBand)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This changes band ownership. Other devices may need to be set up again.")
            }
    }
}

private struct ConnectionAttemptView: View {
    let attempt: ConnectionAttempt

    var body: some View {
        PanelGroup("Latest connection attempt", caption: "This app session. Earlier attempts remain in the journal.") {
            VStack(alignment: .leading, spacing: 8) {
                if let started = attempt.startedAt {
                    Text(started, style: .time).font(.caption).foregroundStyle(Color.muted)
                    Text(attempt.steps.map(\.rawValue).joined(separator: " → ")).font(.caption)
                    if let failure = attempt.failure {
                        Text(failure.title).font(.label)
                        if let result = failure.result, let channel = failure.channel {
                            Text("\(String(format: "0x%08X", result)) · channel \(channel)")
                                .font(.caption).monospaced()
                        }
                        Text(failure.detail).font(.caption).foregroundStyle(Color.muted)
                    } else if attempt.outcome == .stopped {
                        Text("Disconnected.").font(.caption).foregroundStyle(Color.muted)
                    }
                } else {
                    Text("No connection attempted in this app session.").font(.caption).foregroundStyle(Color.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(Metric.inset)
        }
    }
}

struct GestureDetail: View {
    let event: GestureEvent
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                row("Finger", "\(event.finger) (\(event.fingerCode))")
                row("Raw", "\(event.action) (\(event.actionCode))")
                row("Derived", "\(event.derivedAction) (\(event.derivedActionCode))")
                row("Synthetic", event.synthetic ? "Yes" : "No")
                row("Sequence", "\(event.sequence) · \(event.stream.rawValue)")
                row("Band clock", String(event.deviceTimestamp))
                row("Phone uptime", String(format: "%.3f s", event.received.uptime))
                row("Received", event.received.wallTime.formatted(date: .omitted, time: .standard))
                row("App state", event.received.applicationState, last: true)
            }
            .panel().padding(Metric.gutter)
        }
        .page()
        .navigationTitle(event.plainTitle).navigationBarTitleDisplayMode(.inline)
    }
    private func row(_ title: String, _ value: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            ValueRow(title, height: Metric.rowDense) { Text(value).monospacedDigit() }
            if !last { Rule() }
        }
    }
}
