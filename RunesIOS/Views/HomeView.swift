import SwiftUI

struct HomeActions {
    var connect: () -> Void = {}
    var disconnect: () -> Void = {}
    var setUp: () -> Void = {}
    var openSettings: () -> Void = {}
    var openMappings: () -> Void = {}
    var openApplications: () -> Void = {}
    var openApp: (RunesApp) -> Void = { _ in }
    var resolve: (SessionIssue.Action) -> Void = { _ in }
}

/// One large ring, its state in words, the band's facts, and the Mac link.
struct HomeView: View {
    let status: BandStatus
    var actions = HomeActions()
    @State private var confirmDisconnect = false
    @State private var appeared = false
    @AppStorage("home.pinnedApps") private var pinnedRaw = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 12)
            Button(action: ringTapped) {
                HairlineRing(phase: status.phase, gesture: status.gesture)
                    .frame(maxWidth: 360)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RingButtonStyle())
            .accessibilityLabel("Band connection")
            .accessibilityValue(status.phase.title)
            .accessibilityHint(ringHint)
            .disabled(status.phase == .connecting)

            VStack(spacing: 8) {
                Text(status.phase.title).font(.display).tracking(-0.6)
                    .contentTransition(.opacity)
                if !showsIssueCard {
                    Text(status.detail).font(.bodyText).foregroundStyle(Color.muted)
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                }
            }
            .padding(.horizontal, Metric.gutter)
            .accessibilityElement(children: .combine)
            .animation(.standard, value: status.phase)

            if showsIssueCard, let issue = status.issue {
                IssueCard(issue: issue, action: actions.resolve)
                    .padding(.horizontal, Metric.gutter).padding(.top, 20)
                    .transition(.opacity)
            } else if status.phase == .connecting || status.phase == .connected {
                Button("Disconnect") { confirmDisconnect = true }
                    .buttonStyle(.quiet).padding(.top, 8)
            }

            Spacer(minLength: 20)
            pinnedApps
        }
        .animation(.standard, value: status.issue)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 5)
        .onAppear { withAnimation(.entrance) { appeared = true } }
        .page()
        .confirmationDialog("Disconnect your band?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive, action: actions.disconnect)
        } message: {
            Text("Runes will stop listening for gestures until you connect again.")
        }
    }

    private var header: some View {
        HStack {
            batteryRing
            Spacer()
            Button(action: actions.openApplications) {
                LucideIcon(.layoutGrid, size: 20)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Applications")
            Button(action: actions.openMappings) {
                LucideIcon(.hand, size: 20)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Mappings")
            Button(action: actions.openSettings) {
                Image(systemName: "gearshape").font(.system(size: 17, weight: .regular))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.leading, Metric.gutter).padding(.trailing, 8).padding(.top, 4)
    }

    /// Band battery as a hairline ring with its percentage, at the leading edge of the header.
    private var batteryRing: some View {
        let level = status.battery.map { Double(min(max($0, 0), 100)) / 100 }
        return HStack(spacing: 8) {
            Text(status.battery.map { "\($0)%" } ?? "—")
                .font(.caption).monospacedDigit().foregroundStyle(Color.muted)
                .contentTransition(.numericText())
            ZStack {
                Circle().stroke(Color.rule, lineWidth: 2)
                Circle().trim(from: 0, to: level ?? 0)
                    .stroke(level.map { $0 <= 0.15 } == true ? Color.muted : Color.ink,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 20, height: 20)
            .animation(.standard, value: status.battery)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Band battery")
        .accessibilityValue(status.battery.map { "\($0) percent" } ?? "Unknown")
    }

    private var pins: [RunesApp?] {
        let ids = pinnedRaw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        return (0..<3).map { i in i < ids.count ? RunesApp(rawValue: ids[i]) : nil }
    }

    private func setPin(_ app: RunesApp?, at index: Int) {
        var list = pins.map { $0?.rawValue ?? "" }
        list[index] = app?.rawValue ?? ""
        pinnedRaw = list.joined(separator: ",")
    }

    /// Three slots for favourite applications.
    private var pinnedApps: some View {
        HStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { i in pinSlot(i) }
        }
        .padding(.horizontal, Metric.gutter).padding(.bottom, 8)
    }

    @ViewBuilder private func pinSlot(_ index: Int) -> some View {
        if let app = pins[index] {
            Button { actions.openApp(app) } label: {
                VStack(spacing: 8) {
                    LucideIcon(app.icon, size: 20)
                    Text(app.title).font(.caption).lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 72)
                .panel()
                .contentShape(Rectangle())
            }
            .buttonStyle(RingButtonStyle())
            .contextMenu {
                Menu("Replace") { appChoices(index) }
                Button("Unpin", role: .destructive) { setPin(nil, at: index) }
            }
            .accessibilityLabel(app.title)
            .accessibilityHint("Opens the app. Touch and hold to unpin.")
        } else {
            Menu { appChoices(index) } label: {
                VStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 15, weight: .regular))
                    Text("Pin app").font(.caption)
                }
                .foregroundStyle(Color.muted)
                .frame(maxWidth: .infinity, minHeight: 72)
                .overlay(RoundedRectangle(cornerRadius: Metric.panel)
                    .strokeBorder(Color.rule, style: StrokeStyle(lineWidth: Metric.hairline, dash: [4, 3])))
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Empty slot \(index + 1)")
            .accessibilityHint("Pins an application here.")
        }
    }

    @ViewBuilder private func appChoices(_ index: Int) -> some View {
        ForEach(RunesApp.allCases) { app in
            Button { setPin(app, at: index) } label: { Label(app.title, systemImage: "pin") }
        }
    }

    /// The issue card carries the sentence, so the line under the title steps aside.
    private var showsIssueCard: Bool {
        guard let issue = status.issue else { return false }
        return status.phase == .attention || issue.isGentle
    }

    private var ringHint: String {
        switch status.phase {
        case .notSetUp: return "Starts setup."
        case .paused: return "Connects your band."
        case .connected: return "Asks to disconnect."
        case .attention: return status.issue?.actionTitle ?? ""
        case .connecting: return ""
        }
    }

    private func ringTapped() {
        switch status.phase {
        case .notSetUp: actions.setUp()
        case .paused: actions.connect()
        case .connected: confirmDisconnect = true
        case .attention: if let issue = status.issue { actions.resolve(issue.action) } else { actions.connect() }
        case .connecting: break
        }
    }
}

/// The ring gives under the finger slightly, without any fill or shadow.
private struct RingButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.standard, value: configuration.isPressed)
    }
}

/// Applications that can be pinned to the home screen.
enum RunesApp: String, CaseIterable, Identifiable {
    case workouts
    var id: String { rawValue }
    var title: String { switch self { case .workouts: "Workouts" } }
    var icon: Lucide { switch self { case .workouts: .dumbbell } }
    var route: AppRoute { switch self { case .workouts: .workouts } }
}
