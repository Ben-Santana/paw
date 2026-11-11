import Foundation

/// Decides which of an app's triggers a band gesture completes, combos and double-tap
/// waits included, exactly as Mappings would: a `MappingEngine` with its own clock.
@MainActor
final class TriggerDecider {
    /// Told the id of each mapping that was made.
    var onFire: ((String) -> Void)?
    private var engine = MappingEngine()
    private var ticker: Timer?

    func configure(_ mappings: [Mapping]) {
        engine.configure(mappings)
        ticker?.invalidate(); ticker = nil
    }

    func receive(_ kind: GestureKind) { receive(ComboStep(kind)) }

    /// A tap, swipe or hold, or a rotation or movement from `MotionDetector`.
    func receive(_ step: ComboStep) {
        handle(engine.receive(step, at: ProcessInfo.processInfo.systemUptime))
        if !engine.isIdle, ticker == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
    }

    /// The band's orientation quaternion, for air steps.
    func orientation(_ q: [Double]) {
        engine.orientation(q, at: ProcessInfo.processInfo.systemUptime)
    }

    private func tick() {
        handle(engine.tick(at: ProcessInfo.processInfo.systemUptime))
        if engine.isIdle { ticker?.invalidate(); ticker = nil }
    }

    private func handle(_ events: [MappingEngine.Event]) {
        for event in events {
            if case .fire(let id, _) = event { onFire?(id) }
        }
    }
}
