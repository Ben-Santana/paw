import Foundation

// Cook's recipes: plain text in, structure out. A recipe is pasted as text or fetched
// from a link (most recipe sites publish schema.org Recipe data in the page), sorted into
// a title, ingredients and steps, and every duration a step mentions becomes a timer the
// band can start. Foundation only, so it is tested without the app (Tests/CookTests.swift).

struct Recipe: Codable, Identifiable, Hashable, Sendable {
    var id = UUID().uuidString.lowercased()
    var title: String
    var ingredients: [String]
    var steps: [String]
    /// "Serves 4", as the recipe says it.
    var yield: String? = nil
    /// The link it came from, if any.
    var source: String? = nil
    var added = Date()
    var cooked = 0
    var lastCooked: Date? = nil

    static let titleLimit = 80
    static let fallbackTitle = "Untitled recipe"

    /// A recipe can be cooked once it has something to do.
    var isUsable: Bool { !steps.isEmpty }

    func durations(step index: Int) -> [StepDuration] {
        steps.indices.contains(index) ? DurationFinder.find(in: steps[index]) : []
    }
    var timerCount: Int { steps.reduce(0) { $0 + DurationFinder.find(in: $1).count } }

    /// "8 ingredients · 6 steps · 3 timers".
    var summary: String {
        var parts: [String] = []
        if !ingredients.isEmpty { parts.append(ingredients.count == 1 ? "1 ingredient" : "\(ingredients.count) ingredients") }
        parts.append(steps.count == 1 ? "1 step" : "\(steps.count) steps")
        let timers = timerCount
        if timers > 0 { parts.append(timers == 1 ? "1 timer" : "\(timers) timers") }
        return parts.joined(separator: " · ")
    }

    /// The recipe as text that `RecipeParser.parse` reads back to the same recipe; this is
    /// what the editor shows.
    var text: String {
        var lines = [title, ""]
        if let yield, !yield.isEmpty { lines += [yield, ""] }
        if !ingredients.isEmpty {
            lines.append("Ingredients")
            lines += ingredients.map { "- \($0)" }
            lines.append("")
        }
        lines.append("Steps")
        lines += steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
        return lines.joined(separator: "\n")
    }

    /// The host of the source link, for a caption.
    var sourceHost: String? {
        guard let source, let host = URL(string: source)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: Durations

/// A length of time a step mentions, and where, so it can be underlined and started.
struct StepDuration: Hashable, Sendable {
    var seconds: Int
    /// UTF-16 range of the phrase in the step's text.
    var location: Int
    var length: Int
    /// "10–12 minutes", as written.
    var phrase: String
    /// What the time is for, when the sentence says: "Simmer".
    var label: String?

    /// "20 min", "1 h 30", "45 s".
    var short: String { DurationFinder.short(seconds) }
}

enum DurationFinder {
    private static let number = #"(?:(?:\d+|one|two|three|four|five) and a half|\d+(?:[.,]\d+)?(?:\s*[½¼¾⅓⅔]|\s+\d/\d)?|\d/\d|[½¼¾⅓⅔]|half an?|an?|one|two|three|four|five|six|seven|eight|nine|ten|twelve|fifteen|twenty|thirty|forty[- ]five|forty|sixty|ninety|a few|a couple of)"#
    private static let unit = #"(?:hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)"#
    private static let regex = try! NSRegularExpression(
        pattern: "(?<![\\w/.,])(\(number))(?:\\s*(?:-|–|—|to|or)\\s*(\(number)))?[\\s-]*(\(unit))\\b", options: [.caseInsensitive])
    private static let andAHalf = try! NSRegularExpression(pattern: #"^\s+and\s+a\s+half\b"#, options: [.caseInsensitive])

    private static let words: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "forty-five": 45, "forty five": 45, "sixty": 60, "ninety": 90,
        "half a": 0.5, "half an": 0.5, "a few": 3, "a couple of": 2,
    ]
    private static let fractions: [Character: Double] = ["½": 0.5, "¼": 0.25, "¾": 0.75, "⅓": 1.0 / 3, "⅔": 2.0 / 3]

    /// Seconds in one of a unit, by its first letter.
    private static func scale(_ unit: String) -> Int {
        switch unit.lowercased().first { case "h": 3600; case "m": 60; default: 1 }
    }

    private static func value(_ text: String) -> Double? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if let word = words[t] { return word }
        if t.hasSuffix(" and a half") {
            return value(String(t.dropLast(11))).map { $0 + 0.5 }
        }
        if let last = t.last, let fraction = fractions[last] {
            let whole = t.dropLast().trimmingCharacters(in: .whitespaces)
            return whole.isEmpty ? fraction : Double(whole).map { $0 + fraction }
        }
        if t.contains("/") {
            let parts = t.split(separator: " ")
            let ratio = parts.last!.split(separator: "/").compactMap { Double($0) }
            guard ratio.count == 2, ratio[1] != 0 else { return nil }
            return (parts.count == 2 ? Double(parts[0]) ?? 0 : 0) + ratio[0] / ratio[1]
        }
        return Double(t.replacingOccurrences(of: ",", with: "."))
    }

    private struct Match { var range: NSRange; var seconds: Double; var scale: Int }

    static func find(in text: String) -> [StepDuration] {
        let ns = text as NSString
        var matches: [Match] = []
        for result in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let first = ns.substring(with: result.range(at: 1)), unit = ns.substring(with: result.range(at: 3))
            // "5 m" and "30 s" only count after a digit; "a m…" is not a time.
            if unit.count == 1, first.rangeOfCharacter(from: .decimalDigits) == nil { continue }
            guard var amount = value(first) else { continue }
            var range = result.range
            let rest = ns.substring(from: NSMaxRange(range))
            // "a minute less than the packet says" compares two times; it isn't one to wait for.
            if ["a", "an"].contains(first.lowercased()), rest.range(of: #"^\s+(less|more|longer|before|earlier|later|ago|early)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { continue }
            // "an hour and a half".
            if let more = andAHalf.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
                amount += 0.5; range.length += more.range.length
            }
            matches.append(Match(range: range, seconds: amount * Double(scale(unit)), scale: scale(unit)))
        }
        // "1 hour 30 minutes" is one time; "30 seconds to 1 minute" is a range, and a range
        // runs to its lower end, where it is worth looking in the pan.
        var merged: [Match] = []
        for match in matches {
            if let last = merged.last {
                let between = ns.substring(with: NSRange(location: NSMaxRange(last.range), length: match.range.location - NSMaxRange(last.range)))
                    .trimmingCharacters(in: .whitespaces).lowercased()
                let joined = NSRange(location: last.range.location, length: NSMaxRange(match.range) - last.range.location)
                if ["", ",", "and", ", and"].contains(between), match.scale < last.scale {
                    merged[merged.count - 1] = Match(range: joined, seconds: last.seconds + match.seconds, scale: match.scale)
                    continue
                }
                if ["to", "-", "–", "—", "or"].contains(between) {
                    merged[merged.count - 1] = Match(range: joined, seconds: min(last.seconds, match.seconds), scale: last.scale)
                    continue
                }
            }
            merged.append(match)
        }
        return merged.compactMap { match in
            let seconds = Int(match.seconds.rounded())
            guard (10...86_400).contains(seconds) else { return nil }
            return StepDuration(seconds: seconds, location: match.range.location, length: match.range.length,
                                phrase: ns.substring(with: match.range), label: label(before: match.range.location, in: ns))
        }
    }

    // What a time is for: the nearest cooking verb before it in the same sentence. Verbs
    // that describe what the hands do meanwhile ("stirring") only count when nothing else does.
    private static let verbs: [(stem: String, label: String)] = [
        ("simmer", "Simmer"), ("boil", "Boil"), ("bak", "Bake"), ("roast", "Roast"), ("cook", "Cook"), ("fry", "Fry"), ("fried", "Fry"),
        ("saut", "Sauté"), ("sear", "Sear"), ("brown", "Brown"), ("grill", "Grill"), ("broil", "Broil"), ("toast", "Toast"),
        ("steam", "Steam"), ("poach", "Poach"), ("brais", "Braise"), ("stew", "Stew"), ("blanch", "Blanch"), ("reduc", "Reduce"),
        ("caramel", "Caramelize"), ("sweat", "Sweat"), ("soften", "Soften"), ("melt", "Melt"), ("preheat", "Preheat"), ("heat", "Heat"),
        ("warm", "Warm"), ("microwav", "Microwave"), ("rest", "Rest"), ("stand", "Stand"), ("sit", "Rest"), ("cool", "Cool"),
        ("chill", "Chill"), ("refrigerat", "Chill"), ("freez", "Freeze"), ("marinat", "Marinate"), ("soak", "Soak"), ("steep", "Steep"),
        ("brew", "Brew"), ("infus", "Infuse"), ("proof", "Proof"), ("rise", "Rise"), ("rising", "Rise"), ("knead", "Knead"),
        ("thicken", "Thicken"), ("crisp", "Crisp"), ("smok", "Smoke"), ("drain", "Drain"), ("set aside", "Set aside"),
    ]
    private static let meanwhile: [(stem: String, label: String)] = [
        ("stir", "Stir"), ("whisk", "Whisk"), ("mix", "Mix"), ("beat", "Beat"), ("blend", "Blend"), ("process", "Process"),
        ("puls", "Pulse"), ("toss", "Toss"), ("flip", "Flip"), ("turn", "Turn"), ("fold", "Fold"), ("shak", "Shake"), ("press", "Press"),
    ]

    private static func label(before location: Int, in text: NSString) -> String? {
        let head = text.substring(to: location)
        let sentence = head.components(separatedBy: CharacterSet(charactersIn: ".;!?")).last ?? head
        let lowered = sentence.lowercased()
        let tokens = lowered.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        func nearest(_ list: [(stem: String, label: String)]) -> String? {
            for (index, token) in tokens.enumerated().reversed() {
                // "set aside" is the one two-word verb.
                if token == "set", tokens.indices.contains(index + 1), tokens[index + 1] == "aside" { return "Set aside" }
                if let hit = list.first(where: { !$0.stem.contains(" ") && token.hasPrefix($0.stem) }) { return hit.label }
            }
            return nil
        }
        return nearest(verbs) ?? nearest(meanwhile)
    }

    /// "20 min", "1 h 30", "45 s", "1 h".
    static func short(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        let hours = seconds / 3600, minutes = seconds % 3600 / 60, rest = seconds % 60
        if hours > 0 { return minutes > 0 ? "\(hours) h \(String(format: "%02d", minutes))" : "\(hours) h" }
        return rest > 0 ? "\(minutes) min \(rest) s" : "\(minutes) min"
    }

    /// A running clock: "19:42", "1:05:00".
    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: Text

enum RecipeParser {
    private enum Section { case intro, ingredients, steps, other }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let ingredientsHeader = #"^(ingredients?|what you(['’]ll| will)? need|you(['’]ll| will) need|shopping list)$"#
    private static let stepsHeader = #"^(method|directions?|instructions?|steps?|preparation|procedure|how to make( it| this)?|to make)$"#
    private static let otherHeader = #"^(notes?|tips?|cook['’]?s notes?|nutrition( facts| information| info)?|equipment|variations?|storage|substitutions?|serving suggestions?|to serve|faqs?|description|about)$"#
    private static let groupHeader = #"^for (the )?.{1,40}$"#
    private static let meta = #"^(prep|cook|cooking|total|active|inactive|resting|rest|chill|chilling|ready in|time)( time)?\s*[:\-–]"#
    private static let yieldLine = #"^(serves|servings?|yields?|makes)\b"#
    private static let numbering = #"^(step\s*)?\d{1,2}\s*[.):\-–]\s+|^step\s*\d{1,2}\s*[.:\-–]?\s*"#
    private static let bullet = #"^[-•*·▢☐□✓✔◦‣–—]+\s*"#
    private static let ingredientStart = #"^(\d|[½¼¾⅓⅔]|a |an |one |two |three |half |pinch|dash|handful|splash|knob|salt|pepper|juice of|zest of|olive oil|oil for)"#

    /// A header line without its markdown, trailing colon or emphasis.
    private static func bare(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "#*_ \t:"))
    }
    private static func strip(_ pattern: String, _ line: String) -> String {
        line.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }
    private static func looksLikeIngredient(_ line: String) -> Bool {
        let body = strip(bullet, line)
        return body.count <= 70 && !body.hasSuffix(".") && body.split(separator: " ").count <= 10 && matches(ingredientStart, body)
    }
    private static func looksLikeStep(_ line: String) -> Bool {
        matches(numbering, line) || line.count > 60 || (line.hasSuffix(".") && line.split(separator: " ").count > 3)
    }

    /// Sorts pasted text into a recipe. It never fails: text with nothing recognisable
    /// becomes a recipe with no steps, which the editor reports.
    static func parse(_ text: String) -> Recipe {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let hasHeaders = lines.contains { matches(ingredientsHeader, bare($0)) || matches(stepsHeader, bare($0)) }

        var title: String?
        var yield: String?
        var ingredients: [String] = []
        var stepLines: [String] = []
        var section = Section.intro

        for raw in lines where !raw.isEmpty {
            let header = bare(raw)
            if matches(ingredientsHeader, header) { section = .ingredients; continue }
            if matches(stepsHeader, header) { section = .steps; continue }
            if matches(otherHeader, header) { section = .other; continue }
            if matches(meta, header) { continue }
            if matches(yieldLine, header), header.count <= 40 { if yield == nil { yield = header }; continue }

            switch section {
            case .intro:
                if title == nil, raw.count <= 120, !looksLikeIngredient(raw), !matches(numbering, raw) {
                    title = bare(strip(bullet, raw)); continue
                }
                // Without headings the lines sort themselves; with them, this is a description.
                guard !hasHeaders else { continue }
                if looksLikeIngredient(raw) { ingredients.append(strip(bullet, raw)) }
                else if looksLikeStep(raw) { section = .steps; stepLines.append(raw) }
            case .ingredients:
                // A recipe with an ingredients heading but none for the method.
                if !lines.contains(where: { matches(stepsHeader, bare($0)) }), !looksLikeIngredient(raw), looksLikeStep(raw) {
                    section = .steps; stepLines.append(raw); continue
                }
                let item = strip(bullet, raw)
                if !item.isEmpty { ingredients.append(matches(groupHeader, header) ? header + ":" : item) }
            case .steps:
                if matches(groupHeader, header), raw.count <= 44, !raw.hasSuffix(".") { continue }
                stepLines.append(raw)
            case .other:
                continue
            }
        }

        // Numbered steps may be wrapped over several lines; unnumbered lines belong to the one before.
        let numbered = stepLines.contains { matches(numbering, $0) }
        var steps: [String] = []
        for line in stepLines {
            let body = strip(bullet, strip(numbering, line)).trimmingCharacters(in: .whitespaces)
            if numbered, !matches(numbering, line), !steps.isEmpty {
                if !body.isEmpty { steps[steps.count - 1] += (steps[steps.count - 1].isEmpty ? "" : " ") + body }
            } else {
                steps.append(body)
            }
        }
        steps = steps.filter { !$0.isEmpty }
        // One long paragraph reads better a sentence at a time.
        if steps.count == 1, steps[0].count > 200 { steps = sentences(steps[0]) }

        let name = String((title ?? "").prefix(Recipe.titleLimit)).trimmingCharacters(in: .whitespaces)
        return Recipe(title: name.isEmpty ? Recipe.fallbackTitle : name, ingredients: ingredients, steps: steps, yield: yield)
    }

    /// Splits a paragraph at sentence ends, keeping "1.5" and "approx." whole enough.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = [], current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard ".!?".contains(character) else { continue }
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            let after = index + 2 < characters.count ? characters[index + 2] : "A"
            if next == " ", after.isUppercase || after.isNumber, current.count > 12 {
                result.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    /// The link, when the whole text is one.
    static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else { return nil }
        return url
    }

    // MARK: Web pages

    /// Reads the schema.org Recipe that recipe sites publish in the page for search engines.
    static func recipe(fromHTML html: String, source: String?) -> Recipe? {
        guard let regex = try? NSRegularExpression(pattern: #"<script[^>]*type\s*=\s*["']?application/ld\+json["']?[^>]*>(.*?)</script>"#,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let json = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = json.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let found = findRecipe(root), let recipe = recipe(fromSchema: found, source: source) else { continue }
            return recipe
        }
        return nil
    }

    private static func findRecipe(_ value: Any, depth: Int = 0) -> [String: Any]? {
        guard depth < 6 else { return nil }
        if let list = value as? [Any] {
            for item in list { if let hit = findRecipe(item, depth: depth + 1) { return hit } }
        } else if let object = value as? [String: Any] {
            let type = object["@type"]
            if (type as? String) == "Recipe" || (type as? [Any])?.contains(where: { ($0 as? String) == "Recipe" }) == true { return object }
            for key in ["@graph", "mainEntity", "mainEntityOfPage"] {
                if let inner = object[key], let hit = findRecipe(inner, depth: depth + 1) { return hit }
            }
        }
        return nil
    }

    static func recipe(fromSchema object: [String: Any], source: String?) -> Recipe? {
        let ingredients = strings(object["recipeIngredient"] ?? object["ingredients"] ?? [])
        var steps = instructions(object["recipeInstructions"] ?? [])
        if steps.count == 1, steps[0].count > 200 { steps = sentences(steps[0]) }
        guard !steps.isEmpty else { return nil }
        let title = (object["name"] as? String).map(clean) ?? ""
        var yield: String?
        if let text = strings(object["recipeYield"] ?? []).first(where: { !$0.isEmpty }) {
            yield = Int(text) != nil ? "Serves \(text)" : text
        } else if let number = object["recipeYield"] as? NSNumber {
            yield = "Serves \(number)"
        }
        let name = String(title.prefix(Recipe.titleLimit))
        return Recipe(title: name.isEmpty ? Recipe.fallbackTitle : name, ingredients: ingredients, steps: steps, yield: yield, source: source)
    }

    private static func strings(_ value: Any) -> [String] {
        if let text = value as? String { return [clean(text)].filter { !$0.isEmpty } }
        if let list = value as? [Any] { return list.compactMap { $0 as? String }.map(clean).filter { !$0.isEmpty } }
        return []
    }

    /// Instructions come as one string, a list of strings, HowToSteps, or sections of them.
    private static func instructions(_ value: Any) -> [String] {
        if let text = value as? String {
            return text.components(separatedBy: "\n").map(clean).map { strip(numbering, $0) }.filter { !$0.isEmpty }
        }
        if let object = value as? [String: Any] {
            if let inner = object["itemListElement"] { return instructions(inner) }
            if let text = (object["text"] ?? object["name"]) as? String { return [clean(text)].filter { !$0.isEmpty } }
            return []
        }
        if let list = value as? [Any] { return list.flatMap(instructions) }
        return []
    }

    private static let entities = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&lt;": "<", "&gt;": ">",
                                   "&deg;": "°", "&frac12;": "½", "&frac14;": "¼", "&frac34;": "¾", "&ndash;": "–", "&mdash;": "—",
                                   "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“", "&hellip;": "…"]

    /// Plain text from a schema string: no tags, entities decoded, whitespace collapsed.
    static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, character) in entities { result = result.replacingOccurrences(of: entity, with: character) }
        if let numeric = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
            let ns = result as NSString
            for match in numeric.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                let hex = match.range(at: 1).length > 0
                if let code = UInt32(ns.substring(with: match.range(at: 2)), radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    result = (result as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
                }
            }
        }
        return result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}

extension Recipe {
    /// A recipe to try the app with on first launch.
    static let starter = Recipe(
        id: "starter-tomato-pasta",
        title: "Weeknight tomato pasta",
        ingredients: ["400 g spaghetti", "3 tbsp olive oil", "4 cloves garlic, sliced", "1 pinch chilli flakes", "800 g tinned whole tomatoes",
                      "1 tsp salt", "1 handful basil leaves", "Parmesan, to serve"],
        steps: ["Bring a large pot of well-salted water to the boil.",
                "Warm the olive oil in a wide pan over a medium heat. Add the garlic and chilli and cook for 2 minutes, until fragrant but not coloured.",
                "Crush the tomatoes into the pan with your hands, add the salt, and simmer for 15 minutes, stirring now and then.",
                "Cook the spaghetti for 9 minutes, or a minute less than the packet says. Keep a cup of the cooking water.",
                "Toss the drained pasta through the sauce with a splash of the water and let it rest for 1 minute off the heat.",
                "Tear in the basil and serve with parmesan."],
        yield: "Serves 4", added: Date(timeIntervalSince1970: 1_762_000_000))
}
