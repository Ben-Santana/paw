import SwiftUI

struct HomeActions {
    var connect: () -> Void = {}
    var disconnect: () -> Void = {}
    var setUp: () -> Void = {}
    var openSettings: () -> Void = {}
    var resolve: (SessionIssue.Action) -> Void = { _ in }
}

/// One large ring, its state in words, the band's facts, and the Mac link.
struct HomeView: View {
    let status: BandStatus
    var actions = HomeActions()
    @State private var confirmDisconnect = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 12)
            Button(action: ringTapped) {
                HairlineRing(phase: status.phase, pulse: status.gestureCount)
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
            facts
            macLine
        }
        .animation(.standard, value: status.issue)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 5)
        .onAppear { withAnimation(.entrance) { appeared = true } }
        .page()
        .confirmationDialog("Disconnect your band?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive, action: actions.disconnect)
        } message: {
            Text("Neural will stop listening for gestures until you connect again.")
        }
    }

    private var header: some View {
        HStack {
            Text("Neural").font(.geist(22, .medium, relativeTo: .title2)).tracking(-0.9)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: actions.openSettings) {
                Image(systemName: "gearshape").font(.system(size: 17, weight: .regular))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.leading, Metric.gutter).padding(.trailing, 8).padding(.top, 4)
    }

    private var facts: some View {
        HStack(spacing: 0) {
            fact("Battery", status.battery.map { "\($0)%" } ?? "—")
            Rectangle().fill(Color.rule).frame(width: Metric.hairline).padding(.vertical, 12)
            fact("Hand", status.hand.map { $0 == .left ? "Left" : "Right" } ?? "—")
            Rectangle().fill(Color.rule).frame(width: Metric.hairline).padding(.vertical, 12)
            fact("Last gesture", status.lastGesture ?? "—")
        }
        .fixedSize(horizontal: false, vertical: true)
        .panel()
        .padding(.horizontal, Metric.gutter)
    }

    /// The issue card carries the sentence, so the line under the title steps aside.
    private var showsIssueCard: Bool {
        guard let issue = status.issue else { return false }
        return status.phase == .attention || issue.isGentle
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Color.muted)
            Text(value).font(.label).monospacedDigit().lineLimit(2).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var macLine: some View {
        HStack(spacing: 8) {
            if let link = status.macLink {
                Circle().fill(link.localizedCaseInsensitiveContains("connected") ? Color.ink : Color.faint)
                    .frame(width: 6, height: 6).accessibilityHidden(true)
                Text(link).font(.caption).foregroundStyle(Color.muted).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, Metric.gutter).padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.macLink.map { "Mac: \($0)" } ?? "")
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
