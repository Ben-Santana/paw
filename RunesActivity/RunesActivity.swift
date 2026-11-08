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
            } else {
                HStack(spacing: 14) {
                    RunesLogo().frame(width: 28, height: 28)
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
                        Label(workout.title, systemImage: "dumbbell").font(.subheadline).lineLimit(1)
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
                    Image(systemName: "dumbbell")
                } compactTrailing: {
                    if workout.finished { Image(systemName: "checkmark") }
                    else if workout.isCounting { Text("\(workout.reps)").monospacedDigit() }
                    else { Image(systemName: "pause") }
                } minimal: {
                    Image(systemName: "dumbbell")
                }
            }
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { RunesLogo().frame(width: 24, height: 24) }
                DynamicIslandExpandedRegion(.trailing) { BatteryRing(level: context.state.battery, size: 22) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.isStale ? "Open Runes to check status" : context.state.status)
                        LinkIndicators(band: context.state.isConnected, mac: context.state.macConnected)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                RunesLogo().frame(width: 16, height: 16)
            } compactTrailing: {
                BatteryRing(level: context.state.battery, size: 14)
            } minimal: {
                RunesLogo().frame(width: 16, height: 16)
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
            HStack(alignment: .firstTextBaseline) {
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

/// The Runes mark (Lucide "hand", 24-unit grid), stroked so it scales to any size.
private struct RunesLogo: View {
    var body: some View {
        GeometryReader { geo in
            let k = min(geo.size.width, geo.size.height) / 24
            Self.hand
                .applying(CGAffineTransform(scaleX: k, y: k))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2 * k, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Runes")
    }

    private static let hand: Path = {
        var p = Path()
        func finger(x: CGFloat, top: CGFloat, base: CGFloat) {
            p.move(to: CGPoint(x: x + 4, y: base))
            p.addLine(to: CGPoint(x: x + 4, y: top))
            p.addArc(center: CGPoint(x: x + 2, y: top), radius: 2, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
        }
        finger(x: 14, top: 6, base: 11)
        finger(x: 10, top: 4, base: 10); p.addLine(to: CGPoint(x: 10, y: 6))
        finger(x: 6, top: 6, base: 10.5); p.addLine(to: CGPoint(x: 6, y: 14))
        p.move(to: CGPoint(x: 18, y: 8))
        p.addArc(center: CGPoint(x: 20, y: 8), radius: 2, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: 22, y: 14))
        p.addArc(center: CGPoint(x: 14, y: 14), radius: 8, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: 12, y: 22))
        p.addCurve(to: CGPoint(x: 6.01, y: 19.66), control1: CGPoint(x: 9.2, y: 22), control2: CGPoint(x: 7.5, y: 21.14))
        p.addLine(to: CGPoint(x: 2.41, y: 16.06))
        p.addArc(center: CGPoint(x: 3.825, y: 14.65), radius: 2, startAngle: .degrees(135), endAngle: .degrees(315), clockwise: false)
        p.addLine(to: CGPoint(x: 7, y: 15))
        return p
    }()
}
