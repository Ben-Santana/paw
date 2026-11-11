#if DEBUG
import SwiftUI

/// The style guide as a screen: every token and part from Documentation/StyleGuide.md, drawn
/// with the real code. Debug builds only; open the "Style guide" preview or launch with
/// RUNES_SNAPSHOT=style-guide. Nothing here touches the session.
struct StyleGuideGallery: View {
    @State private var segment = "Normal"
    @State private var toggle = true
    @State private var steps = [GestureKind.holdIndex, .swipeUp, .releaseIndex].steps
    @State private var interval = ComboRules.defaultTime

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    intro
                    colours
                    type
                    metrics
                    buttons
                    rows
                    ledger
                    triggers
                    motion
                    icons
                }
                .padding(Metric.gutter).padding(.bottom, 40)
            }
            .page()
            .navigationTitle("Style guide").navigationBarTitleDisplayMode(.inline)
        }
        .tint(Color.ink)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            HairlineRing(phase: .connected).frame(maxWidth: 220).frame(maxWidth: .infinity)
            Text("Ink on paper").font(.display).tracking(-0.6)
            Text("One ring, one sentence, one action. Six colour tokens, five type styles, hairlines instead of boxes, 200 ms motion. The home screen is the reference.")
                .font(.bodyText).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var colours: some View {
        Block {
            HStack(spacing: 8) {
                swatch("paper", Color.paper, border: true)
                swatch("ink", Color.ink)
                swatch("muted", Color.muted)
                swatch("rule", Color.rule)
                swatch("soft", Color.soft, border: true)
                swatch("faint", Color.faint)
            }
            .padding(.top, 12)
        } header: {
            Heading("Colour")
        } footer: {
            Note("Dark mode inverts the same tokens. Red exists only on the swipe-to-delete square.")
        }
    }

    private func swatch(_ name: String, _ color: Color, border: Bool = false) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: Metric.control).fill(color).frame(height: 40)
                .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: border ? Metric.hairline : 0))
            Text(name).font(.geist(10, relativeTo: .caption2)).foregroundStyle(Color.muted)
        }
    }

    private var type: some View {
        Block {
            VStack(alignment: .leading, spacing: 14) {
                specimen("Connected", .display, "display · 28 medium")
                specimen("Workouts", .heading, "heading · 20 medium")
                specimen("Your band is talking to your phone.", .bodyText, "bodyText · 15")
                specimen("Pair another Mac", .label, "label · 14 medium")
                specimen("A light tap when a gesture arrives.", .caption, "caption · 12")
                specimen("{ \"method\": \"POST\" }", .code, "code · footnote mono")
            }
            .padding(.top, 12)
        } header: {
            Heading("Type")
        } footer: {
            Note("Geist, bundled. Every style scales with Dynamic Type. Changing numbers use monospaced digits.")
        }
    }

    private func specimen(_ text: String, _ font: Font, _ meta: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text).font(font)
            Text(meta).font(.geist(10, relativeTo: .caption2)).foregroundStyle(Color.muted)
        }
    }

    private var metrics: some View {
        Block {
            HStack(alignment: .bottom, spacing: 12) {
                radius("chip", Metric.chip, 36)
                radius("control", Metric.control, 44)
                radius("panel", Metric.panel, 56)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("gutter 20 · inset 14").font(.caption).foregroundStyle(Color.muted)
                    Text("rows 44 · 48 · 52").font(.caption).foregroundStyle(Color.muted)
                    Text("tap 44").font(.caption).foregroundStyle(Color.muted)
                }
            }
            .padding(.top, 12)
        } header: {
            Heading("Shape and space")
        }
    }

    private func radius(_ name: String, _ r: CGFloat, _ size: CGFloat) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: r).strokeBorder(Color.ink, lineWidth: Metric.hairline).frame(width: size, height: size)
            Text("\(name) \(Int(r))").font(.geist(10, relativeTo: .caption2)).foregroundStyle(Color.muted)
        }
    }

    private var buttons: some View {
        Block {
            VStack(spacing: 10) {
                Button("Primary") {}.buttonStyle(.primary)
                Button("Secondary") {}.buttonStyle(.secondary)
                Button("Quiet") {}.buttonStyle(.quiet)
                HStack(spacing: 8) {
                    IconButton(.layoutGrid) {}
                    IconButton(.hand) {}
                    IconButton(.settings) {}
                    Spacer()
                    RoundAction(icon: .play, label: "Round") {}
                }
                Button("Capsule action") {}.buttonStyle(CapsuleAction(filled: true))
            }
            .padding(.top, 12)
        } header: {
            Heading("Buttons")
        } footer: {
            Note("One primary per screen. Icons sit in a 44 pt target. Capsules belong to the run screen.")
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 28) {
            PanelGroup("Panel group", caption: "A caption under the panel explains the group in one sentence.") {
                ValueRow("Battery") { Text("82%").monospacedDigit() }
                Rule()
                LinkRow("Privacy") { EmptyView() }
                Rule()
                ActionRow("Pair Mac", icon: .qrCode) {}
                Rule()
                Toggle(isOn: $toggle) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Haptics on gesture").font(.bodyText)
                        Text("A light tap when a gesture arrives.").font(.caption).foregroundStyle(Color.muted)
                    }
                }
                .padding(.horizontal, Metric.inset).padding(.vertical, 10)
            }
            IssueCard(issue: .bandNotNearby) { _ in }
        }
    }

    private var triggers: some View {
        Block {
            VStack(alignment: .leading, spacing: 0) {
                TriggerRow(title: "Add a point", detail: "To the selected player.", steps: steps) {}
                Hairline()
                TriggerComposer(steps: $steps, interval: $interval,
                                rules: .gestureOrCombo(GestureKind.motions, next: ScoreTrigger.comboChoices, allowsNone: true))
                    .padding(.top, 16)
            }
        } header: {
            Heading("Gestures and combos")
        } footer: {
            Note("One composer everywhere: touch a step to change it on the pad, the dashed slot to add one. The line marks steps made with a finger held.")
        }
    }

    private var ledger: some View {
        Block {
            VStack(alignment: .leading, spacing: 0) {
                ledgerRow("Push", "Bench press · Overhead press · Dips")
                Hairline()
                ledgerRow("Pull", "Rows · Pull-ups · Curls")
                Hairline(delay: 0.1)
                AddRow(title: "Add day") {}
                HairlineSegments(selection: $segment, options: ["Low", "Normal", "High"], title: \.self)
                    .padding(.top, 8)
            }
        } header: {
            Heading("Ledger", count: 2)
        } footer: {
            Note("Content lists are open: hairlines draw in from the left, rows dim when pressed, nothing is boxed.")
        }
    }

    private func ledgerRow(_ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.heading)
                Text(detail).font(.caption).foregroundStyle(Color.muted)
            }
            Spacer()
            Chevron()
        }
        .padding(.vertical, 14)
    }

    private var motion: some View {
        Block {
            VStack(alignment: .leading, spacing: 8) {
                motionRow("standard", "ease-out 200 ms", "state and control changes")
                motionRow("entrance", "ease-out 350 ms", "a screen's content arriving")
                motionRow("lively", "spring 300 ms · 0.3", "press feedback on round controls")
                motionRow("ring", "700 ms tweens", "pods moving, from the Mac's Hairline")
            }
            .padding(.top, 12)
        } header: {
            Heading("Motion")
        } footer: {
            Note("Reduce Motion removes every movement and keeps the states.")
        }
    }

    private func motionRow(_ name: String, _ curve: String, _ use: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(.label).frame(width: 80, alignment: .leading)
            Text(curve).font(.caption).monospacedDigit()
            Spacer()
            Text(use).font(.caption).foregroundStyle(Color.muted).multilineTextAlignment(.trailing)
        }
    }

    private var icons: some View {
        Block {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 12) {
                ForEach(Lucide.allCases, id: \.self) { icon in
                    LucideIcon(icon, size: 20).frame(maxWidth: .infinity, minHeight: 32)
                }
            }
            .padding(.top, 12)
        } header: {
            Heading("Icons", count: Lucide.allCases.count)
        } footer: {
            Note("Lucide 0.468 at a 1.5 stroke, the Mac's set. Sizes 20, 18, 16 and 14. No SF Symbols.")
        }
    }
}

#Preview("Style guide") { StyleGuideGallery() }
#Preview("Style guide · dark") { StyleGuideGallery().preferredColorScheme(.dark) }
#endif
