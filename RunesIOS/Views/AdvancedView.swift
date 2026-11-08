import SwiftUI

struct AdvancedValues {
    var relayStatus: String
    var events: [GestureEvent] = []
    var eventCount = 0
    var canImportMacSetup = false
    var journalProblem: String?
}

struct AdvancedActions {
    var export: () async -> URL? = { nil }
    var clear: () -> Void = {}
    var pairMac: (String) -> Void = { _ in }
    var importMacSetup: (String) -> Void = { _ in }
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
                section("Journal", footer: "Up to 4 MB of connection events and gestures, kept on this phone. Exports contain gesture data and device identifiers.") {
                    actionRow(exporting ? "Preparing…" : "Export journal") {
                        exporting = true
                        Task { exported = await actions.export(); exporting = false }
                    }
                    .disabled(exporting)
                    if let exported {
                        rule
                        ShareLink(item: exported) { rowLabel("Share journal", chevron: true) }.buttonStyle(.plain)
                    }
                    rule
                    actionRow("Clear journal") { confirmClear = true }
                    if let problem = values.journalProblem {
                        rule
                        Text(problem).font(.caption).foregroundStyle(Color.muted).padding(14)
                    }
                }
                section("Band setup", footer: nil) {
                    actionRow("Use my Mac’s band setup") { scanner = .identity }.disabled(!values.canImportMacSetup)
                }
                section("Raw packets", footer: "\(values.eventCount) received this session. Newest first, up to 200.") {
                    if values.events.isEmpty {
                        Text("Gesture packets will appear here.").font(.bodyText).foregroundStyle(Color.muted)
                            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    }
                    ForEach(Array(values.events.prefix(200).enumerated()), id: \.element.id) { offset, event in
                        if offset > 0 { rule }
                        NavigationLink { GestureDetail(event: event) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title).font(.bodyText)
                                    Text("\(event.layer) · #\(event.sequence)").font(.caption).foregroundStyle(Color.muted)
                                }
                                Spacer()
                                Text(event.received.wallTime, style: .time).font(.caption).foregroundStyle(Color.muted)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8).contentShape(Rectangle())
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

    private var rule: some View { Rectangle().fill(Color.rule).frame(height: Metric.hairline).padding(.leading, 14) }

    private func section<Content: View>(_ title: String, footer: String?, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title).padding(.leading, 2)
            VStack(spacing: 0, content: content).panel()
            if let footer { Text(footer).font(.caption).foregroundStyle(Color.muted).padding(.horizontal, 2) }
        }
    }

    private func rowLabel(_ title: String, chevron: Bool = false) -> some View {
        HStack {
            Text(title).font(.bodyText)
            Spacer()
            if chevron { Image(systemName: "square.and.arrow.up").font(.system(size: 13)).foregroundStyle(Color.muted) }
        }
        .padding(.horizontal, 14).frame(minHeight: 48).contentShape(Rectangle())
    }

    private func actionRow(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(title) }.buttonStyle(.plain)
    }
}

struct AdvancedScreen: View {
    @ObservedObject var controller: SessionController
    var body: some View {
        let snapshot = controller.snapshot
        AdvancedView(values: AdvancedValues(relayStatus: controller.relayStatus, events: snapshot.events, eventCount: snapshot.eventCount,
                                            canImportMacSetup: snapshot.selected != nil && !snapshot.wantsConnection,
                                            journalProblem: snapshot.journalError),
                     actions: AdvancedActions(export: controller.exportJournal, clear: controller.clearJournal,
                                              pairMac: controller.pairRelay,
                                              importMacSetup: { text in if let id = snapshot.selected { controller.importIdentityQR(text, for: id) } }))
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
            HStack { Text(title).font(.bodyText); Spacer(); Text(value).font(.bodyText).foregroundStyle(Color.muted).monospacedDigit() }
                .padding(.horizontal, 14).frame(minHeight: 44)
            if !last { Rectangle().fill(Color.rule).frame(height: Metric.hairline).padding(.leading, 14) }
        }
        .accessibilityElement(children: .combine)
    }
}
