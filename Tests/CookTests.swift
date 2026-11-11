// Isolated checks for Cook: times found in a step, pasted text sorted into a recipe, a recipe read from a web page,
// and a recipe being cooked (steps, timers that start, pause, reset and take a minute one at a time, the band's gestures).
//
//     swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift \
//       RunesIOS/Persistence/IdentityStore.swift RunesIOS/Mappings/MappingModel.swift RunesIOS/Mappings/AirGesture.swift RunesIOS/Mappings/MappingEngine.swift \
//       RunesIOS/Mappings/TriggerRules.swift RunesIOS/Mappings/CommandTrigger.swift \
//       Shared/ProfileIcon.swift Shared/SVGPath.swift Shared/LucideData.swift \
//       RunesIOS/Cook/RecipeParser.swift RunesIOS/Cook/CookModel.swift Tests/CookTests.swift -o /private/tmp/runes-cook-tests && /private/tmp/runes-cook-tests
import Foundation

@main
struct CookTests {
    static func seconds(_ text: String) -> [Int] { DurationFinder.find(in: text).map(\.seconds) }

    static func main() {
        // MARK: Times in a step
        precondition(seconds("Simmer for 20 minutes.") == [1200])
        precondition(seconds("Bake 25-30 min until golden") == [1500], "A range runs to its lower end")
        precondition(seconds("Cook for 10 to 12 minutes") == [600])
        precondition(seconds("Roast for 1 hour 30 minutes") == [5400], "Hours and minutes are one time")
        precondition(seconds("Braise for 1 hour and 15 minutes.") == [4500])
        precondition(seconds("Rest for 1½ hours") == [5400])
        precondition(seconds("Chill for 1 1/2 hours") == [5400])
        precondition(seconds("Leave for an hour") == [3600])
        precondition(seconds("Leave for an hour and a half") == [5400])
        precondition(seconds("Prove for half an hour") == [1800])
        precondition(seconds("Whisk for 30 seconds") == [30])
        precondition(seconds("Blend 30 seconds to 1 minute") == [30], "A range across units is one time")
        precondition(seconds("A 5-minute rest helps") == [300])
        precondition(seconds("Cook for a few minutes") == [180])
        precondition(seconds("Fry for two minutes each side") == [120])
        precondition(seconds("Sear 3 minutes, then simmer 20 minutes") == [180, 1200], "Two times in a step are two timers")
        precondition(seconds("Microwave for 45 s") == [45])
        // Things that look like times and aren't.
        precondition(seconds("Add 2 medium onions and 400 g tomatoes") == [])
        precondition(seconds("Heat the oven to 200 C") == [])
        precondition(seconds("Use a 23 cm tin and 10 ml oil") == [])
        precondition(seconds("Serves 4 hungry people") == [])
        precondition(seconds("Wait a second") == [], "Too short to be worth a timer")
        precondition(seconds("Add 3 slices of bread") == [])
        precondition(seconds("Cook for 9 minutes, or a minute less than the packet says") == [540], "A comparison isn't a time to wait for")
        precondition(seconds("Cook 1 minute more") == [60])

        let simmer = DurationFinder.find(in: "Crush the tomatoes into the pan and simmer for 15 minutes, stirring now and then.")[0]
        precondition(simmer.label == "Simmer" && simmer.phrase == "15 minutes" && simmer.short == "15 min")
        let text = "Crush the tomatoes into the pan and simmer for 15 minutes, stirring now and then." as NSString
        precondition(text.substring(with: NSRange(location: simmer.location, length: simmer.length)) == "15 minutes")
        precondition(DurationFinder.find(in: "Cook, stirring often, for 8 minutes.")[0].label == "Cook", "The main verb wins over what the hands do")
        precondition(DurationFinder.find(in: "Whisk for 30 seconds")[0].label == "Whisk")
        precondition(DurationFinder.find(in: "Drain. Then set aside for 10 minutes")[0].label == "Set aside")
        precondition(DurationFinder.find(in: "After 5 minutes, add the cream")[0].label == nil)
        precondition(DurationFinder.short(5400) == "1 h 30" && DurationFinder.short(3600) == "1 h" && DurationFinder.short(90) == "1 min 30 s")
        precondition(DurationFinder.clock(1182) == "19:42" && DurationFinder.clock(3900) == "1:05:00" && DurationFinder.clock(-3) == "0:00")

        // MARK: Pasted text
        let pasted = """
        Tomato soup

        A quick one for cold days.
        Prep time: 10 minutes
        Serves 4

        ## Ingredients
        - 1 onion, chopped
        • 800 g tinned tomatoes
        For the topping
        2 tbsp cream

        Method:
        1. Soften the onion in oil for 5 minutes.
        2. Add the tomatoes and simmer
           for 20 minutes.
        3) Blend until smooth.

        Notes
        Freezes well for 3 months.
        """
        let soup = RecipeParser.parse(pasted)
        precondition(soup.title == "Tomato soup")
        precondition(soup.yield == "Serves 4")
        precondition(soup.ingredients == ["1 onion, chopped", "800 g tinned tomatoes", "For the topping:", "2 tbsp cream"], "\(soup.ingredients)")
        precondition(soup.steps == ["Soften the onion in oil for 5 minutes.", "Add the tomatoes and simmer for 20 minutes.", "Blend until smooth."], "\(soup.steps)")
        precondition(soup.timerCount == 2 && soup.summary == "4 ingredients · 3 steps · 2 timers")
        precondition(soup.isUsable)

        // The text a recipe shows in the editor reads back as the same recipe.
        let again = RecipeParser.parse(soup.text)
        precondition(again.title == soup.title && again.ingredients == soup.ingredients && again.steps == soup.steps && again.yield == soup.yield)
        let starter = RecipeParser.parse(Recipe.starter.text)
        precondition(starter.steps == Recipe.starter.steps && starter.ingredients == Recipe.starter.ingredients && starter.title == Recipe.starter.title)
        precondition(Recipe.starter.timerCount == 4)

        // No headings at all: short lines that start like amounts are ingredients, sentences are steps.
        let bare = RecipeParser.parse("""
        Garlic bread
        1 baguette
        50 g butter
        2 cloves garlic
        Mash the garlic into the butter and spread it on the sliced baguette.
        Bake for 12 minutes until the edges are crisp.
        """)
        precondition(bare.title == "Garlic bread" && bare.ingredients.count == 3 && bare.steps.count == 2, "\(bare)")

        // An ingredients heading but none for the method.
        let half = RecipeParser.parse("Toast\nIngredients\n2 slices bread\nbutter\nToast the bread for 2 minutes, then butter it while it is hot.")
        precondition(half.ingredients == ["2 slices bread", "butter"] && half.steps.count == 1, "\(half)")

        // One long paragraph becomes a step per sentence.
        let paragraph = RecipeParser.parse("Rice\nSteps\n" + "Rinse the rice until the water runs clear. Put it in a pan with 1.5 times its volume of water. Bring to the boil, cover, and cook for 12 minutes. Take it off the heat and leave it covered for 10 minutes. Fluff with a fork.")
        precondition(paragraph.steps.count == 5 && paragraph.steps[1].contains("1.5 times"), "\(paragraph.steps)")

        precondition(!RecipeParser.parse("").isUsable && RecipeParser.parse("").title == Recipe.fallbackTitle)
        precondition(!RecipeParser.parse("Just a title").isUsable)

        precondition(RecipeParser.link(in: "  https://example.com/recipes/soup \n")?.host() == "example.com")
        precondition(RecipeParser.link(in: "Soup https://example.com") == nil && RecipeParser.link(in: "example.com") == nil)
        precondition(RecipeParser.link(in: "ftp://example.com/soup") == nil)

        // MARK: A web page
        let html = """
        <html><head><script type="application/ld+json">{"@type":"WebSite","name":"Site"}</script>
        <script type='application/ld+json'>
        {"@context":"https://schema.org","@graph":[{"@type":"Person","name":"A Cook"},
          {"@type":["Recipe","NewsArticle"],"name":"Lemon &amp; herb chicken","recipeYield":["4","4 servings"],
           "recipeIngredient":["1 chicken","2 lemons, <b>zested</b>"],
           "recipeInstructions":[
             {"@type":"HowToSection","name":"Roast","itemListElement":[
               {"@type":"HowToStep","text":"Heat the oven to 200&deg;C."},
               {"@type":"HowToStep","text":"<p>Roast for 1 hour&nbsp;15 minutes.</p>"}]},
             {"@type":"HowToStep","text":"Rest for 10 minutes before carving."}]}]}
        </script></head><body></body></html>
        """
        guard let chicken = RecipeParser.recipe(fromHTML: html, source: "https://www.example.com/chicken") else { preconditionFailure("No recipe found") }
        precondition(chicken.title == "Lemon & herb chicken" && chicken.yield == "Serves 4")
        precondition(chicken.ingredients == ["1 chicken", "2 lemons, zested"], "\(chicken.ingredients)")
        precondition(chicken.steps == ["Heat the oven to 200°C.", "Roast for 1 hour 15 minutes.", "Rest for 10 minutes before carving."], "\(chicken.steps)")
        precondition(chicken.sourceHost == "example.com" && chicken.durations(step: 1).map(\.seconds) == [4500])
        let plain = RecipeParser.recipe(fromHTML: "<script type=\"application/ld+json\">{\"@type\":\"Recipe\",\"name\":\"Tea\",\"recipeInstructions\":\"1. Boil water.\\n2. Steep for 3 minutes.\"}</script>", source: nil)
        precondition(plain?.steps == ["Boil water.", "Steep for 3 minutes."], "\(String(describing: plain?.steps))")
        precondition(RecipeParser.recipe(fromHTML: "<html><body>No data here</body></html>", source: nil) == nil)
        precondition(RecipeParser.recipe(fromHTML: "<script type=\"application/ld+json\">{broken</script>", source: nil) == nil)

        // MARK: Cooking
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var cook = CookSession(recipe: .starter, at: t0)
        precondition(cook.step == 0 && cook.count == 6 && cook.position == "Step 1 of 6" && !cook.finished)
        precondition(cook.apply(.previous, at: t0) == nil, "Nothing before the first step")
        precondition(cook.apply(.timer, at: t0) == nil, "The first step mentions no time")
        precondition(cook.apply(.addMinute, at: t0) == nil, "No timer to extend")
        precondition(cook.apply(.reset, at: t0) == nil && cook.apply(.timerDown, at: t0) == nil && cook.selectedTimer == nil)
        precondition(cook.apply(.next, at: t0) == .step(1))

        // Step 2: "cook for 2 minutes". The timer gesture starts it, pauses it, and starts it again.
        guard case .started(let garlic)? = cook.apply(.timer, at: t0) else { preconditionFailure("Timer should start") }
        precondition(garlic.total == 120 && garlic.label == "Cook" && garlic.step == 1 && garlic.remaining(at: t0) == 120)
        precondition(cook.running(at: t0).count == 1 && cook.ringing(at: t0).isEmpty && cook.selectedTimer?.id == garlic.id)
        precondition(garlic.progress(at: t0.addingTimeInterval(60)) == 0.5)
        guard case .paused(let held)? = cook.apply(.timer, at: t0.addingTimeInterval(30)) else { preconditionFailure("Timer should pause") }
        precondition(held.isPaused && held.paused == 90 && held.remaining(at: t0.addingTimeInterval(500)) == 90, "Paused time stands still")
        precondition(!held.isRunning(at: t0.addingTimeInterval(500)) && !held.isRinging(at: t0.addingTimeInterval(500)) && held.progress(at: t0) == 0.25)
        precondition(cook.running(at: t0.addingTimeInterval(40)).isEmpty && cook.nextEnd(after: t0.addingTimeInterval(40)) == nil, "A paused timer never rings")
        precondition(cook.live(at: t0.addingTimeInterval(40)).count == 1, "It is still worth showing")
        // A minute goes to a paused timer too.
        guard case .extended(let fatter)? = cook.apply(.addMinute, at: t0.addingTimeInterval(45)) else { preconditionFailure("Should extend") }
        precondition(fatter.paused == 150 && fatter.total == 180)
        guard case .resumed(let going)? = cook.apply(.timer, at: t0.addingTimeInterval(100)) else { preconditionFailure("Timer should start again") }
        precondition(going.paused == nil && going.end == t0.addingTimeInterval(250) && going.isRunning(at: t0.addingTimeInterval(101)))
        // Reset puts it back as it was before it was started.
        precondition(cook.apply(.reset, at: t0.addingTimeInterval(110)) == .reset && cook.timers.isEmpty && cook.selectedTimer == nil)
        precondition(cook.apply(.reset, at: t0.addingTimeInterval(111)) == nil, "Nothing to reset")
        precondition(cook.apply(.timerDown, at: t0) == nil && cook.apply(.timerUp, at: t0) == nil, "One time on this step: nothing to move between")
        guard case .started(let garlic2)? = cook.apply(.timer, at: t0) else { preconditionFailure("Timer should start") }

        // Step 3's simmer runs alongside.
        cook.apply(.next, at: t0.addingTimeInterval(30))
        guard case .started(let simmer3)? = cook.apply(.timer, at: t0.addingTimeInterval(30)) else { preconditionFailure("Timer should start") }
        precondition(simmer3.total == 900 && simmer3.label == "Simmer")
        precondition(cook.live(at: t0.addingTimeInterval(31)).map(\.label) == ["Cook", "Simmer"], "Least time left first")
        precondition(cook.nextEnd(after: t0.addingTimeInterval(31)) == t0.addingTimeInterval(120))

        // Another minute goes to the selected timer while nothing rings.
        guard case .extended(let longer)? = cook.apply(.addMinute, at: t0.addingTimeInterval(40)) else { preconditionFailure("Should extend") }
        precondition(longer.id == simmer3.id && longer.total == 960 && longer.end == t0.addingTimeInterval(990))

        // The garlic rings at two minutes; the timer gesture stops it rather than pausing the simmer.
        let rung = t0.addingTimeInterval(125)
        precondition(cook.ringing(at: rung).map(\.id) == [garlic2.id] && cook.timer(step: 1, slot: 0)!.remaining(at: rung) == 0)
        guard case .extended(let more)? = cook.apply(.addMinute, at: rung) else { preconditionFailure("Should extend") }
        precondition(more.id == garlic2.id && more.end == rung.addingTimeInterval(60) && more.total == 60, "A rung timer starts again with a minute")
        precondition(cook.ringing(at: rung).isEmpty)
        let rungAgain = rung.addingTimeInterval(61)
        precondition(cook.ringing(at: rungAgain).count == 1)
        precondition(cook.apply(.timer, at: rungAgain) == .stopped)
        precondition(cook.ringing(at: rungAgain).isEmpty && cook.live(at: rungAgain).map(\.label) == ["Simmer"])
        precondition(cook.timer(step: 1, slot: 0)?.stopped == true && cook.selectedTimer?.isRunning(at: rungAgain) == true, "The simmer was left alone")

        // A timer's own button: one that rang and was stopped starts afresh; a ringing one stops by itself.
        guard case .started(let afresh)? = cook.toggle(step: 1, slot: 0, at: rungAgain) else { preconditionFailure("Should start afresh") }
        precondition(cook.timers.filter { $0.step == 1 }.count == 1 && afresh.id != garlic2.id && afresh.total == 120)
        precondition(cook.toggle(step: 1, slot: 0, at: rungAgain.addingTimeInterval(130)) == .stopped)
        precondition(cook.timer(step: 2, slot: 0)?.stopped == false)
        cook.reset(step: 1, slot: 0)
        precondition(cook.timer(step: 1, slot: 0) == nil)
        precondition(cook.start(step: 0, slot: 0, at: rungAgain) == nil && cook.start(step: 9, slot: 0, at: rungAgain) == nil)

        // To the end and back.
        cook.go(to: 5)
        precondition(cook.isLast && cook.apply(.next, at: rungAgain) == .finished && cook.finished && cook.position == "Done")
        precondition(cook.apply(.next, at: rungAgain) == nil && cook.apply(.reset, at: rungAgain) == nil)
        precondition(cook.apply(.previous, at: rungAgain) == .step(5) && !cook.finished)
        cook.go(to: 99); precondition(cook.step == 5)
        cook.toggle(ingredient: 2); cook.toggle(ingredient: 4); cook.toggle(ingredient: 2); cook.toggle(ingredient: 40)
        precondition(cook.ready == [4])

        // A session survives being saved, timers and all.
        let saved = try! JSONEncoder().encode(cook)
        precondition(try! JSONDecoder().decode(CookSession.self, from: saved) == cook)

        // MARK: A step with several times
        let steak = RecipeParser.parse("Steak\nSteps\n1. Sear for 3 minutes, turn and cook for 2 minutes more, then rest for 5 minutes.\n2. Slice and serve.")
        var pan = CookSession(recipe: steak, at: t0)
        precondition(pan.durations.map(\.seconds) == [180, 120, 300] && pan.slot == 0 && pan.selectedTimer == nil)
        // Each is started, paused, reset and extended on its own; the commands act on the one selected.
        guard case .started(let sear)? = pan.apply(.timer, at: t0) else { preconditionFailure("Should start") }
        precondition(sear.slot == 0 && sear.total == 180)
        precondition(pan.apply(.timerDown, at: t0) == .selected(1) && pan.slot == 1 && pan.selectedTimer == nil)
        guard case .started(let turn)? = pan.apply(.timer, at: t0.addingTimeInterval(10)) else { preconditionFailure("Should start the second") }
        precondition(turn.slot == 1 && turn.total == 120 && pan.running(at: t0.addingTimeInterval(11)).count == 2)
        guard case .paused(let turnHeld)? = pan.apply(.timer, at: t0.addingTimeInterval(20)) else { preconditionFailure("Should pause the second") }
        precondition(turnHeld.slot == 1 && pan.timer(step: 0, slot: 0)?.isRunning(at: t0.addingTimeInterval(21)) == true, "The first keeps counting")
        guard case .extended(let turnMore)? = pan.apply(.addMinute, at: t0.addingTimeInterval(25)) else { preconditionFailure("Should extend the second") }
        precondition(turnMore.slot == 1 && turnMore.paused == 170 && pan.timer(step: 0, slot: 0)?.total == 180)
        precondition(pan.apply(.timerDown, at: t0) == .selected(2) && pan.apply(.timerDown, at: t0) == .selected(0), "Round to the first again")
        precondition(pan.apply(.timerUp, at: t0) == .selected(2) && pan.apply(.timerUp, at: t0) == .selected(1))
        precondition(pan.apply(.reset, at: t0.addingTimeInterval(30)) == .reset && pan.timer(step: 0, slot: 1) == nil && pan.timer(step: 0, slot: 0) != nil)
        // With the selected one idle, a minute goes to the one that is counting.
        guard case .extended(let searMore)? = pan.apply(.addMinute, at: t0.addingTimeInterval(40)) else { preconditionFailure("Should extend the first") }
        precondition(searMore.slot == 0 && searMore.total == 240)
        // Choosing directly, and leaving the step, which starts the next step at its first time.
        pan.select(slot: 2); precondition(pan.slot == 2)
        pan.select(slot: 7); precondition(pan.slot == 2, "No such timer")
        pan.apply(.next, at: t0); precondition(pan.slot == 0 && pan.durations.isEmpty && pan.selectedTimer == nil)
        pan.apply(.previous, at: t0); precondition(pan.slot == 0)
        pan.go(to: 0, slot: 1); precondition(pan.step == 0 && pan.slot == 1)
        precondition(try! JSONDecoder().decode(CookSession.self, from: try! JSONEncoder().encode(pan)) == pan)

        // MARK: Gestures
        var controls = CookControls.standard
        precondition(controls.command(for: .swipeRight) == .next && controls.command(for: .doubleTapIndex) == .timer)
        precondition(controls.command(for: .swipeDown) == .timerDown && controls.command(for: .swipeUp) == .timerUp && controls.command(for: .holdMiddle) == .reset)
        precondition(controls.reserved == [.swipeRight, .swipeLeft, .swipeUp, .swipeDown, .doubleTapIndex, .tapIndex, .doubleTapMiddle, .tapMiddle, .holdMiddle, .releaseMiddle])
        controls.set(.swipeRight, for: .timer)
        precondition(controls.gesture(for: .timer) == .swipeRight && controls.gesture(for: .next) == .doubleTapIndex, "Taking a gesture swaps")
        controls.set(nil, for: .addMinute)
        precondition(controls.gesture(for: .addMinute) == nil && !controls.reserved.contains(.doubleTapMiddle))
        controls.set(.holdIndex, for: .previous)
        precondition(controls.reserved.contains(.releaseIndex))
        let stored = try! JSONEncoder().encode(controls)
        precondition(try! JSONDecoder().decode(CookControls.self, from: stored) == controls, "None stays None once saved")
        // Settings saved before reset and timer selection existed get those gestures, unless something has them.
        let older = try! JSONDecoder().decode(CookControls.self, from: Data(#"{"gestures":["next","swipe-right","previous","swipe-up","timer","double-tap-index"]}"#.utf8))
        precondition(older.gesture(for: .reset) == .holdMiddle && older.gesture(for: .timerDown) == .swipeDown)
        precondition(older.gesture(for: .timerUp) == nil && older.gesture(for: .previous) == .swipeUp, "A gesture already in use is left where it is")

        // A command can take a combo. The engine Mappings uses decides when it was made.
        controls = .standard
        let twice = CommandTrigger(steps: [.swipeUp, .swipeUp].steps, intervalMs: 500)
        controls.setTrigger(twice, for: .addMinute)
        precondition(controls.trigger(for: .addMinute) == twice && controls.gesture(for: .addMinute) == nil && controls.command(for: .doubleTapMiddle) == nil)
        precondition(!controls.reserved.contains(.doubleTapMiddle) && !controls.reserved.contains(.tapMiddle) && controls.reserved.contains(.swipeUp))
        precondition(try! JSONDecoder().decode(CookControls.self, from: JSONEncoder().encode(controls)) == controls, "Combos round-trip")
        var engine = MappingEngine(mappings: controls.mappings)
        func made(_ events: [MappingEngine.Event]) -> [CookCommand] {
            events.compactMap { if case .fire(let id, _) = $0 { controls.command(forMapping: id) } else { nil } }
        }
        precondition(made(engine.receive(.swipeRight, at: 0)) == [.next])
        precondition(made(engine.receive(.swipeUp, at: 1)).isEmpty, "A swipe up waits for the combo that starts with it")
        precondition(made(engine.tick(at: 1.2)).isEmpty && made(engine.tick(at: 1.6)) == [.timerUp], "and is the previous timer once the combo's time runs out")
        precondition(made(engine.receive(.swipeUp, at: 3) + engine.receive(.swipeUp, at: 3.3) + engine.tick(at: 5)) == [.addMinute], "Twice in time adds a minute, and only that")
        controls.setTrigger(twice, for: .reset)
        precondition(controls.trigger(for: .reset) == twice && controls.gesture(for: .addMinute) == .holdMiddle, "Taking a combo swaps too")
        precondition(!controls.usesMotion, "No motion step, no motion sensors")
        controls.setTrigger(CommandTrigger(steps: [ComboStep(.holdIndex), .movement(.z), ComboStep(.releaseIndex)]), for: .next)
        precondition(controls.usesMotion && controls.reserved.isSuperset(of: [.movement, .holdIndex, .releaseIndex]))
        engine = MappingEngine(mappings: controls.mappings)
        precondition(made(engine.receive(.holdIndex, at: 10) + engine.receive(.movement(.z), at: 14) + engine.receive(.releaseIndex, at: 15)) == [.next],
                     "Held, so the movement has no time limit")

        print("Cook checks passed")
    }
}
