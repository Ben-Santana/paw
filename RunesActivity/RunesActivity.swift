import ActivityKit
import WidgetKit
import SwiftUI

@main
struct RunesActivityBundle: WidgetBundle {
    var body: some Widget {
        BandSessionActivity()
        OneAppWidget()
        FourAppsWidget()
    }
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
            } else if let cook = context.state.cook {
                CookLockScreen(cook: cook)
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
            if let cook = context.state.cook {
                // The step, and its timers: one as a number, several as circles.
                return DynamicIsland {
                    DynamicIslandExpandedRegion(.leading) {
                        Text(cook.position).font(.headline).lineLimit(1).frame(maxHeight: .infinity)
                    }
                    DynamicIslandExpandedRegion(.trailing) {
                        CookTimers(timers: cook.timers, number: 26, circle: 26).frame(maxHeight: .infinity)
                    }
                } compactLeading: {
                    Text(cook.finished ? "Done" : "\(cook.step + 1)/\(cook.count)").monospacedDigit()
                } compactTrailing: {
                    CookTimers(timers: Array(cook.timers.prefix(3)), number: 15, circle: 15, spacing: 4).frame(maxWidth: 60)
                } minimal: {
                    if let timer = cook.timers.first { TimerCircle(timer: timer, size: 16) }
                    else { Text(cook.finished ? "✓" : "\(cook.step + 1)").monospacedDigit() }
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

/// Which step, and its timers. One timer is its time, counting by itself; more than one
/// are circles that fill as they run out.
private struct CookLockScreen: View {
    let cook: CookActivityState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(cook.position).font(.headline)
            Spacer(minLength: 12)
            CookTimers(timers: cook.timers, number: 32, circle: 30)
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
    }
}

/// A recipe's timers: a lone one as a number, several as status circles.
private struct CookTimers: View {
    let timers: [CookActivityTimer]
    /// Point size of the number, and width of each circle.
    let number: CGFloat
    let circle: CGFloat
    var spacing: CGFloat = 10

    var body: some View {
        if timers.count == 1 {
            TimerCount(timer: timers[0]).font(.system(size: number, weight: .medium).monospacedDigit())
        } else if timers.count > 1 {
            HStack(spacing: spacing) {
                ForEach(timers) { TimerCircle(timer: $0, size: circle) }
            }
        }
    }
}

/// A timer's time left, counted by the system between updates; it stands still, dimmed,
/// while paused, and reads 0:00 once it is up.
private struct TimerCount: View {
    let timer: CookActivityTimer
    var body: some View {
        if let left = timer.remaining {
            Text(left >= 3600 ? String(format: "%d:%02d:%02d", left / 3600, left % 3600 / 60, left % 60) : String(format: "%d:%02d", left / 60, left % 60))
                .foregroundStyle(.secondary)
        } else if timer.ringing || timer.end <= Date() {
            Text("0:00")
        } else {
            Text(timerInterval: Date()...timer.end, countsDown: true).multilineTextAlignment(.trailing)
        }
    }
}

/// A timer as a circle: a ring that fills as the time runs out (drawn by the system, so
/// it moves between updates), a dimmed ring standing still while paused, and a solid
/// disc once the time is up.
private struct TimerCircle: View {
    let timer: CookActivityTimer
    let size: CGFloat

    private var line: CGFloat { max(2, size * 0.14) }
    private var start: Date { timer.end.addingTimeInterval(-Double(max(1, timer.total))) }

    var body: some View {
        ZStack {
            if let left = timer.remaining {
                Circle().stroke(Color.white.opacity(0.25), lineWidth: line)
                Circle().trim(from: 0, to: 1 - min(1, Double(left) / Double(max(1, timer.total))))
                    .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else if timer.ringing || timer.end <= Date() {
                Circle().fill(Color.white)
            } else {
                ProgressView(timerInterval: start...timer.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
        }
        .padding(line / 2)
        .frame(width: size, height: size)
        .accessibilityLabel(timer.remaining != nil ? "Timer paused" : timer.ringing ? "Timer done" : "Timer running")
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
                // No names: the colour says who. A ring round it marks the player the band changes.
                VStack(spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(ScoreTint.fill(score.tint(index))).frame(width: 9, height: 9)
                            .overlay { if score.selected == index { Circle().stroke(.primary, lineWidth: 1.5).padding(-3.5) } }
                        if let standing = score.standing(index) {
                            Text(standing).font(.caption).monospacedDigit().lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 16)
                    Text(score.value(index))
                        .font(.system(size: count > 4 ? 22 : count > 2 ? 28 : 34, weight: .medium).monospacedDigit())
                        .contentTransition(.numericText())
                    // The points still to win the game, as on the score screen: open rings,
                    // and the last one filled.
                    HStack(spacing: 4) {
                        let left = score.left(index)
                        ForEach(0..<min(left, 6), id: \.self) { _ in
                            Circle().strokeBorder(.primary, lineWidth: 1.2)
                                .background(Circle().fill(.primary).opacity(left == 1 ? 1 : 0))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .frame(height: 12)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([score.name(index), score.value(index), score.standing(index), score.pointName(index)].compactMap { $0 }.joined(separator: ", "))
            }
        }
    }
}

private extension ScoreActivityState {
    func name(_ index: Int) -> String { names.indices.contains(index) ? names[index] : "" }
    func value(_ index: Int) -> String {
        if let labels, labels.indices.contains(index) { return labels[index] }
        return scores.indices.contains(index) ? "\(scores[index])" : "0"
    }
    func standing(_ index: Int) -> String? {
        guard let standings, standings.indices.contains(index), !standings[index].isEmpty else { return nil }
        return standings[index]
    }
    func left(_ index: Int) -> Int { toGo.map { $0.indices.contains(index) ? max(0, $0[index]) : 0 } ?? 0 }
    func pointName(_ index: Int) -> String? {
        guard let pointNames, pointNames.indices.contains(index), !pointNames[index].isEmpty else { return nil }
        return pointNames[index]
    }
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
