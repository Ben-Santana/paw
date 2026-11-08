import ActivityKit
import WidgetKit
import SwiftUI

@main
struct NeuralActivityBundle: WidgetBundle {
    var body: some Widget { BandSessionActivity() }
}

struct BandSessionActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BandActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "waveform").font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Neural Band").font(.headline)
                    Text(context.isStale ? "Open Neural to check status" : context.state.status).font(.subheadline)
                }
                Spacer()
                Text(context.attributes.startedAt, style: .timer).monospacedDigit().font(.caption)
            }.padding().activityBackgroundTint(Color(.secondarySystemBackground))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label("Neural", systemImage: "waveform") }
                DynamicIslandExpandedRegion(.trailing) { Text(context.attributes.startedAt, style: .timer).monospacedDigit() }
                DynamicIslandExpandedRegion(.bottom) { Text(context.isStale ? "Open Neural to check status" : context.state.status) }
            } compactLeading: {
                Image(systemName: "waveform")
            } compactTrailing: {
                Image(systemName: context.isStale ? "clock" : (context.state.isConnected ? "link" : "ellipsis"))
            } minimal: {
                Image(systemName: "waveform")
            }
        }
    }
}
