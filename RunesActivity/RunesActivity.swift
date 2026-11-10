import ActivityKit
import WidgetKit
import SwiftUI

@main
struct RunesActivityBundle: WidgetBundle {
    var body: some Widget { BandSessionActivity() }
}

struct BandSessionActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BandActivityAttributes.self) { context in
            if let workout = context.state.workout {
                WorkoutLockScreen(workout: workout, connected: context.state.isConnected)
                    .padding().activityBackgroundTint(Color(.secondarySystemBackground))
            } else if let score = context.state.score {
                ScoreLockScreen(score: score, connected: context.state.isConnected)
                    .padding().activityBackgroundTint(Color(.secondarySystemBackground))
            } else {
                HStack(spacing: 14) {
                    ProfileMark(icon: context.state.profileIcon).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.isStale ? "Open Runes to check status" : context.state.status).font(.subheadline)
                        LinkIndicators(band: context.state.isConnected, mac: context.state.macConnected)
                    }
                    Spacer()
                    BatteryRing(level: context.state.battery, size: 22)
                }.padding().activityBackgroundTint(Color(.secondarySystemBackground))
            }
        } dynamicIsland: { context in
            if let workout = context.state.workout {
                return DynamicIsland {
                    DynamicIslandExpandedRegion(.leading) {
                        HStack(spacing: 6) {
                            WorkoutGlyph(group: workout.group, size: 22)
                            Text(workout.title).font(.subheadline).lineLimit(1)
                        }
                    }
                    DynamicIslandExpandedRegion(.trailing) {
                        if workout.isCounting { Text("\(workout.reps)").font(.title2.monospacedDigit()) }
                    }
                    DynamicIslandExpandedRegion(.bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workout.finished ? workout.detail : "\(workout.detail) · \(workout.status)").font(.caption)
                            if let last = workout.last { Text(last).font(.caption).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } compactLeading: {
                    WorkoutGlyph(group: workout.group, size: 18)
                } compactTrailing: {
                    if workout.finished { Image(systemName: "checkmark") }
                    else if workout.isCounting { Text("\(workout.reps)").monospacedDigit() }
                    else { Image(systemName: "pause") }
                } minimal: {
                    WorkoutGlyph(group: workout.group, size: 18)
                }
            }
            if let score = context.state.score {
                // Two players show both numbers; more show the player the band is on.
                let focus = score.selected ?? 0
                return DynamicIsland {
                    DynamicIslandExpandedRegion(.bottom) { ScoreRow(score: score) }
                } compactLeading: {
                    if score.selected == nil { Text("\(score.value(0))").monospacedDigit() }
                    else { Circle().fill(ScoreTint.fill(score.tint(focus))).frame(width: 9, height: 9) }
                } compactTrailing: {
                    Text("\(score.value(score.selected ?? 1))").monospacedDigit()
                } minimal: {
                    Text(score.selected == nil ? "\(score.value(0))–\(score.value(1))" : "\(score.value(focus))")
                        .monospacedDigit().minimumScaleFactor(0.6)
                }
            }
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { ProfileMark(icon: context.state.profileIcon).frame(width: 24, height: 24) }
                DynamicIslandExpandedRegion(.trailing) { BatteryRing(level: context.state.battery, size: 22) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.isStale ? "Open Runes to check status" : context.state.status)
                        LinkIndicators(band: context.state.isConnected, mac: context.state.macConnected)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                ProfileMark(icon: context.state.profileIcon).frame(width: 16, height: 16)
            } compactTrailing: {
                BatteryRing(level: context.state.battery, size: 14)
            } minimal: {
                ProfileMark(icon: context.state.profileIcon).frame(width: 16, height: 16)
            }
        }
    }
}

/// Current set, its live count, the last logged set and what comes next.
private struct WorkoutLockScreen: View {
    let workout: WorkoutActivityState
    let connected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                WorkoutGlyph(group: workout.group, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workout.title).font(.headline)
                    Text(workout.detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if workout.isCounting {
                    Text("\(workout.reps)").font(.system(size: 34, weight: .medium).monospacedDigit())
                        .contentTransition(.numericText())
                }
            }
            HStack(spacing: 6) {
                Circle().fill(workout.isCounting ? Color.primary : Color.secondary).frame(width: 6, height: 6)
                Text(connected ? workout.status : "Band disconnected").font(.caption)
            }
            if workout.last != nil || workout.next != nil {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    if let last = workout.last { Text(last).lineLimit(1) }
                    if let next = workout.next { Text(next).lineLimit(1).foregroundStyle(.secondary) }
                }.font(.caption)
            }
        }
    }
}

/// The current exercise's muscle glyph in white; a dumbbell before a group is known, a check
/// when the workout is done, and a runner for cardio.
private struct WorkoutGlyph: View {
    let group: ExerciseGroup?
    let size: CGFloat

    var body: some View {
        Group {
            if let group, group != .cardio {
                MuscleFigureGlyph(group: group, size: size, ink: .white, outline: .white.opacity(0.45),
                                  idle: .white.opacity(0.35), lineWidth: size < 24 ? 1 : 0.8)
            } else {
                Image(systemName: group == .cardio ? "figure.run" : "dumbbell").font(.system(size: size * 0.6))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Every player of a game, the numbers as large as the banner allows.
private struct ScoreLockScreen: View {
    let score: ScoreActivityState
    let connected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ScoreRow(score: score)
            if !connected { Text("Band disconnected").font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ScoreRow: View {
    let score: ScoreActivityState

    var body: some View {
        let count = score.names.count
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Circle().fill(ScoreTint.fill(score.tint(index))).frame(width: 7, height: 7)
                        Text(score.name(index)).font(.caption).lineLimit(1)
                            .foregroundStyle(score.selected == index ? .primary : .secondary)
                    }
                    Text("\(score.value(index))")
                        .font(.system(size: count > 4 ? 22 : count > 2 ? 28 : 34, weight: .medium).monospacedDigit())
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private extension ScoreActivityState {
    func name(_ index: Int) -> String { names.indices.contains(index) ? names[index] : "" }
    func value(_ index: Int) -> Int { scores.indices.contains(index) ? scores[index] : 0 }
    func tint(_ index: Int) -> Int { tints.indices.contains(index) ? tints[index] : index }
}

/// Band battery as a filled ring, no number. Empty track until the band reports a level.
private struct BatteryRing: View {
    let level: Int?
    let size: CGFloat

    var body: some View {
        let fraction = Double(level ?? 0) / 100
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: size * 0.16)
            Circle().trim(from: 0, to: fraction)
                .stroke(Color.white, style: StrokeStyle(lineWidth: size * 0.16, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityLabel(level.map { "Band battery \($0) percent" } ?? "Band battery unknown")
    }
}

/// Band and Mac link state: a filled dot when connected, an open ring when not.
private struct LinkIndicators: View {
    let band: Bool
    let mac: Bool

    var body: some View {
        HStack(spacing: 12) {
            item("Band", band)
            item("Mac", mac)
        }
        .font(.caption)
    }

    private func item(_ name: String, _ on: Bool) -> some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().strokeBorder(Color.white.opacity(on ? 1 : 0.5), lineWidth: 1)
                if on { Circle().fill(Color.white) }
            }
            .frame(width: 7, height: 7)
            Text(name).foregroundStyle(on ? Color.primary : Color.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(on ? "connected" : "not connected")")
    }
}

/// The active profile's icon in white, or the Runes mark before a profile is known.
private struct ProfileMark: View {
    let icon: String?
    var body: some View {
        ProfileGlyph(key: icon ?? ProfileIcon.logo, lineWidth: 2).foregroundStyle(Color.white)
    }
}
