// Isolated checks for Capture's values: notes by day, waveforms, the level meter, and the gesture or combo that records
// (made again to save, or let go of when it ends with a hold).
//
//     swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift \
//       RunesIOS/Persistence/IdentityStore.swift RunesIOS/Mappings/MappingModel.swift RunesIOS/Mappings/AirGesture.swift RunesIOS/Mappings/MappingEngine.swift \
//       Shared/ProfileIcon.swift Shared/SVGPath.swift Shared/LucideData.swift \
//       RunesIOS/Capture/CaptureModel.swift Tests/CaptureTests.swift -o /private/tmp/runes-capture-tests && /private/tmp/runes-capture-tests
import Foundation

@main
struct CaptureTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 15))!
        func note(hoursAgo: Double, _ text: String = "", _ state: CaptureNote.State = .done) -> CaptureNote {
            CaptureNote(at: now.addingTimeInterval(-hoursAgo * 3600), duration: 5, text: text, state: state, file: "a.m4a")
        }

        // Days, newest first, and notes newest first inside them.
        let notes = [note(hoursAgo: 30, "c"), note(hoursAgo: 1, "a"), note(hoursAgo: 20, "b"), note(hoursAgo: 3, "a2"), note(hoursAgo: 24 * 4), note(hoursAgo: 24 * 40)]
        let days = CaptureDay.group(notes, now: now, calendar: calendar)
        precondition(days.map(\.title).prefix(2) == ["Today", "Yesterday"], "\(days.map(\.title))")
        precondition(days[0].notes.map(\.text) == ["a", "a2"] && days[1].notes.map(\.text) == ["b", "c"])
        precondition(days.count == 4 && days[2].notes.count == 1 && days[3].notes.count == 1)
        precondition(CaptureDay.today(notes, now: now, calendar: calendar) == 2)
        precondition(CaptureDay.group([], now: now, calendar: calendar).isEmpty)
        // 15:00 minus 20 h is 19:00 the day before: yesterday, not today.
        precondition(CaptureDay.group([note(hoursAgo: 16)], now: now, calendar: calendar)[0].title == "Yesterday")

        // What a row says for each state.
        precondition(note(hoursAgo: 1, "Buy milk").summary == "Buy milk" && note(hoursAgo: 1, "Buy milk").hasWords)
        precondition(note(hoursAgo: 1, "", .transcribing).summary == "Writing it down…")
        precondition(note(hoursAgo: 1, "", .done).summary == "Nothing was said")
        precondition(note(hoursAgo: 1, "", .unavailable).summary == "Voice note")
        precondition(note(hoursAgo: 1, "", .pending).summary.hasPrefix("Voice note."))
        precondition(note(hoursAgo: 1, "kept", .pending).summary == "kept", "Words win over the state")

        // Waveforms: any number of peaks to a fixed number of bars, the loudest full height.
        let wave = CaptureRules.waveform([0, 0.1, 0.5, 0.25, 0, 0, 0.05, 0.2], bars: 4)
        precondition(wave == [0.2, 1, 0.04, 0.4], "\(wave)")
        precondition(CaptureRules.waveform([], bars: 3) == [0.04, 0.04, 0.04], "No sound still draws")
        precondition(CaptureRules.waveform([0.3], bars: 5).count == 5 && CaptureRules.waveform([0.3], bars: 5).allSatisfy { $0 == 1 })
        precondition(CaptureRules.waveform([0, 0, 0], bars: 2) == [0.04, 0.04], "Silence is dots, not noise scaled up")
        precondition(CaptureRules.waveform([1, 2], bars: 0).isEmpty)
        let long = CaptureRules.waveform((0..<1000).map { Float($0) / 1000 }, bars: CaptureRules.bars)
        precondition(long.count == CaptureRules.bars && long.last == 1 && long == long.sorted())

        // The meter: silence is still, speech moves it, shouting pins it.
        precondition(CaptureRules.meter(0) == 0 && CaptureRules.meter(0.0001) == 0)
        precondition(CaptureRules.meter(1) == 1 && CaptureRules.meter(4) == 1)
        let quiet = CaptureRules.meter(0.01), speech = CaptureRules.meter(0.1)
        precondition(quiet > 0.15 && quiet < speech && speech < 1, "\(quiet) \(speech)")

        precondition(CaptureRules.clock(7.4) == "0:07" && CaptureRules.clock(750) == "12:30" && CaptureRules.clock(-2) == "0:00")
        precondition(CaptureRules.snippet("Short") == "Short")
        precondition(CaptureRules.snippet("First line\nSecond") == "First line")
        let cut = CaptureRules.snippet(String(repeating: "word ", count: 40), limit: 22)
        precondition(cut == "word word word word wo…", cut)

        // MARK: The gesture that records

        // By default a hold: it records while held, and the finger letting go saves.
        var controls = CaptureControls()
        precondition(controls.trigger == .standard && controls.trigger.gesture == .holdIndex && !controls.trigger.isCombo)
        precondition(controls.trigger.holds && controls.trigger.release == .releaseIndex)
        precondition(controls.reserved == [.holdIndex, .releaseIndex] && controls.sounds && !controls.headset)
        precondition(controls.trigger.start == "Hold your index finger" && controls.trigger.stop == "let go")
        precondition(CaptureTrigger.gesture(.holdMiddle).start == "Hold your middle finger" && CaptureTrigger.gesture(.holdMiddle).release == .releaseMiddle)

        // Any other gesture starts a recording and, made again, saves it.
        let double = CaptureTrigger.gesture(.doubleTapIndex)
        precondition(double.isValid && !double.holds && double.release == nil && double.stop == "do it again")
        precondition(double.reserved == [.doubleTapIndex, .tapIndex], "A double tap takes the tap that begins it")
        precondition(double.start == "Double tap index" && double.mapping.id == "double-tap-index" && double.mapping.isLive)
        precondition(CaptureTrigger.gesture(.swipeUp).isValid && CaptureTrigger.gesture(.swipeUp).reserved == [.swipeUp])
        precondition(!CaptureTrigger.gesture(.releaseIndex).isValid, "A release only exists inside a combo")
        precondition(!CaptureTrigger(steps: []).isValid)

        // Combos: the last step decides. Ending with a finger held, that finger's release saves.
        let swipeHold = CaptureTrigger(steps: [ComboStep(.swipeUp), ComboStep(.holdIndex)])
        precondition(swipeHold.isValid && swipeHold.isCombo && swipeHold.holds && swipeHold.release == .releaseIndex)
        precondition(swipeHold.reserved == [.swipeUp, .holdIndex, .releaseIndex])
        precondition(swipeHold.name == "Swipe up, then tap and hold index" && swipeHold.start == swipeHold.name)
        precondition(swipeHold.mapping.id == CaptureTrigger.comboID && swipeHold.mapping.isLive)
        let swipeDouble = CaptureTrigger(steps: [ComboStep(.swipeUp), ComboStep(.doubleTapMiddle)], intervalMs: 1000)
        precondition(swipeDouble.isValid && !swipeDouble.holds && swipeDouble.reserved == [.swipeUp, .doubleTapMiddle, .tapMiddle])
        // A hold released inside the combo is not a hold at its end.
        let chord = CaptureTrigger(steps: [ComboStep(.holdMiddle), ComboStep(.tapIndex), ComboStep(.releaseMiddle)])
        precondition(chord.isValid && !chord.holds && chord.reserved == [.holdMiddle, .releaseMiddle, .tapIndex])
        precondition(!CaptureTrigger(steps: [ComboStep(.tapIndex), .rotation(.x)]).isValid, "Motion steps would keep the sensors on")
        precondition(!CaptureTrigger(steps: [ComboStep(.swipeUp), ComboStep(.tapIndex)], intervalMs: 123).isValid)
        precondition(!CaptureTrigger.comboChoices(after: []).contains(.rotation) && CaptureTrigger.comboChoices(after: []).contains(.holdIndex))

        // A mapping's gesture ends a recording the same way: by its last step.
        precondition(Mapping.gesture(.holdMiddle).endingRelease == .releaseMiddle && Mapping.gesture(.swipeLeft).endingRelease == nil)
        var combo = Mapping.newCombo(); combo.steps = swipeHold.steps
        precondition(combo.endingRelease == .releaseIndex)
        combo.steps = chord.steps; precondition(combo.endingRelease == nil)
        precondition(MappingAction.capture.problem == nil && MappingAction.capture.kind == .capture && !MappingAction.Kind.capture.needsForeground)
        precondition(try! JSONDecoder().decode([MappingAction].self, from: try! JSONEncoder().encode([MappingAction.capture, .wait(ms: 500)])) == [.capture, .wait(ms: 500)])

        // What the band does to a recording, as the store does it: gestures that belong
        // to the trigger go to an engine; each time it reports the trigger, a recording
        // starts or, if one is under way, is saved; and the finger a hold began it with
        // letting go saves it.
        struct Band {
            var trigger: CaptureTrigger
            var engine = MappingEngine()
            var recording = false, release: GestureKind?
            var log: [String] = []
            init(_ trigger: CaptureTrigger) { self.trigger = trigger; engine.configure([trigger.mapping]) }
            mutating func handle(_ events: [MappingEngine.Event]) {
                for case .fire in events {
                    if recording { recording = false; release = nil; log.append("save") }
                    else { recording = true; release = trigger.release; log.append("start") }
                }
            }
            @discardableResult mutating func make(_ kind: GestureKind, at now: TimeInterval) -> Bool {
                let ends = recording && kind == release
                let mine = trigger.reserved.contains(kind)
                if mine { handle(engine.receive(kind, at: now)) }
                if ends { recording = false; release = nil; log.append("save") }
                return mine
            }
            mutating func wait(until now: TimeInterval) { handle(engine.tick(at: now)) }
        }

        // Hold: starts on the hold, saves on the release, and nothing else is taken.
        var band = Band(.standard)
        precondition(!band.make(.tapIndex, at: 0) && !band.make(.swipeUp, at: 0.1), "Other gestures stay with mappings")
        precondition(band.make(.holdIndex, at: 1) && band.log == ["start"] && band.release == .releaseIndex)
        precondition(band.make(.releaseIndex, at: 4) && band.log == ["start", "save"] && !band.recording)
        band.make(.holdIndex, at: 5); band.make(.releaseIndex, at: 5.2)
        precondition(band.log == ["start", "save", "start", "save"])

        // Double tap: the tap that begins it starts nothing; again saves.
        band = Band(double)
        band.make(.tapIndex, at: 0); band.make(.doubleTapIndex, at: 0.2)
        precondition(band.log == ["start"] && band.release == nil)
        band.make(.tapIndex, at: 1); band.wait(until: 3)
        precondition(band.log == ["start"], "A single tap is not the trigger")
        band.make(.tapIndex, at: 5); band.make(.doubleTapIndex, at: 5.2)
        precondition(band.log == ["start", "save"] && !band.recording)

        // A swipe: once starts, twice saves.
        band = Band(.gesture(.swipeDown))
        band.make(.swipeDown, at: 0); band.make(.swipeDown, at: 9)
        precondition(band.log == ["start", "save"])

        // A combo ending with a hold: starts when the hold completes it, saves on the release.
        band = Band(swipeHold)
        band.make(.holdIndex, at: 0); band.make(.releaseIndex, at: 0.3)
        precondition(band.log.isEmpty, "The hold alone is not the combo")
        band.make(.swipeUp, at: 2); band.make(.holdIndex, at: 2.4)
        precondition(band.log == ["start"] && band.release == .releaseIndex)
        band.make(.releaseIndex, at: 8)
        precondition(band.log == ["start", "save"])
        // Too slow between steps: nothing.
        band.make(.swipeUp, at: 20); band.wait(until: 22); band.make(.holdIndex, at: 22.1); band.make(.releaseIndex, at: 22.5)
        precondition(band.log == ["start", "save"], "\(band.log)")

        // A combo ending in a double tap: the whole combo again saves.
        band = Band(swipeDouble)
        band.make(.swipeUp, at: 0); band.make(.tapMiddle, at: 0.3); band.make(.doubleTapMiddle, at: 0.5)
        precondition(band.log == ["start"])
        band.make(.swipeUp, at: 6); band.make(.tapMiddle, at: 6.3); band.make(.doubleTapMiddle, at: 6.5)
        precondition(band.log == ["start", "save"], "\(band.log)")

        // Settings survive being saved, and older ones still load.
        controls.trigger = swipeHold; controls.headset = true; controls.sounds = false
        let saved = try! JSONEncoder().encode(controls)
        precondition(try! JSONDecoder().decode(CaptureControls.self, from: saved) == controls)
        // Saved when only a hold could record.
        let legacy = try! JSONDecoder().decode(CaptureControls.self, from: Data(#"{"hold":"hold-middle","sounds":false}"#.utf8))
        precondition(legacy.trigger == .gesture(.holdMiddle) && !legacy.sounds && !legacy.headset)
        // Damaged settings fall back rather than failing.
        let odd = try! JSONDecoder().decode(CaptureControls.self, from: Data(#"{"hold":"swipe-up","trigger":{"steps":[]}}"#.utf8))
        precondition(odd.trigger == .standard && odd.sounds && !odd.headset)
        precondition(try! JSONDecoder().decode(CaptureControls.self, from: Data("{}".utf8)) == CaptureControls())

        // Notes survive being saved.
        let kept = [note(hoursAgo: 1, "a"), note(hoursAgo: 2, "", .pending)]
        precondition(try! JSONDecoder().decode([CaptureNote].self, from: try! JSONEncoder().encode(kept)) == kept)

        precondition(CaptureRules.minimum < 1 && CaptureRules.preroll <= 1, "The recorder keeps one second to draw the lead-in from")
        print("Capture checks passed")
    }
}
