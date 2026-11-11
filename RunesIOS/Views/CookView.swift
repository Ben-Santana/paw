import SwiftUI
import UIKit

// Cook: recipes read one step at a time, turned and timed from the band, so wet or
// floury hands never touch the phone. This file is the shelf of recipes, a recipe's page,
// the editor that reads pasted text or a link, and settings. The cooking screen itself is
// CookingView.swift. Drawn as a ledger, like Workouts: type and hairlines, no panels.

struct CookScreen: View {
    @ObservedObject var store: CookStore
    @Binding var path: [AppRoute]
    @State private var adding = false
    @State private var showSettings = false
    @State private var deleting: Recipe?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let session = store.session {
                    CookingBanner(session: session) { path.append(.cooking) }
                        .padding(.bottom, 28)
                }
                Heading("Recipes", count: store.recipes.count)
                ForEach(Array(store.recipes.enumerated()), id: \.element.id) { index, recipe in
                    RecipeRow(index: index, recipe: recipe, cooking: store.session?.recipe.id == recipe.id,
                              open: { path.append(.recipe(recipe.id)) },
                              start: { begin(recipe) })
                        .swipeToDelete(confirms: true) { deleting = recipe }
                        .arrive(index)
                    Hairline(delay: 0.05 * Double(index))
                }
                AddRow(title: "Add a recipe") { adding = true }
                Note("Paste a recipe or a link to one. Runes finds the steps, and the times in them become timers.")
                    .padding(.top, 8)
            }
            .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 40)
            .animation(.entrance, value: store.recipes)
        }
        .page()
        .navigationTitle("Cook").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: { LucideIcon(.settings, size: 19).frame(width: 36, height: 36) }
                    .accessibilityLabel("Cook settings")
            }
        }
        .sheet(isPresented: $adding) {
            RecipeEditor(store: store, recipe: nil) { saved in path.append(.recipe(saved.id)) }
        }
        .sheet(isPresented: $showSettings) { CookSettingsScreen(store: store) }
        .confirmationDialog("Delete \(deleting?.title ?? "this recipe")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete recipe", role: .destructive) { if let deleting { store.delete(deleting.id) } }
        }
    }

    /// Carries on with the recipe already being cooked, or starts this one.
    private func begin(_ recipe: Recipe) {
        if store.session?.recipe.id != recipe.id { store.start(recipe) }
        path.append(.cooking)
    }
}

/// The recipe being cooked: a pulsing dot, where it is, and its soonest timer.
private struct CookingBanner: View {
    let session: CookSession
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    PulseDot()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(session.recipe.title) · cooking").font(.label).lineLimit(1)
                        Text(session.finished ? "Finished" : session.position).font(.caption).foregroundStyle(Color.muted)
                    }
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let timer = session.live(at: context.date).first {
                            Text(timer.isRinging(at: context.date) ? "Done" : DurationFinder.clock(timer.remaining(at: context.date)))
                                .font(.heading).monospacedDigit().contentTransition(.numericText())
                        }
                    }
                    Chevron()
                }
                StepProgress(count: session.count, step: session.step, finished: session.finished)
            }
            .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(PressRow())
        .accessibilityHint("Opens the recipe you’re cooking.")
    }
}

/// A recipe as type and ticks: number, name, one tick per step (taller where a step has
/// a timer), and a hairline play button.
private struct RecipeRow: View {
    let index: Int
    let recipe: Recipe
    let cooking: Bool
    let open: () -> Void
    let start: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Button(action: open) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(String(format: "%02d", index + 1))
                        .font(.geist(12, .medium, relativeTo: .caption)).monospacedDigit().foregroundStyle(Color.muted)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(recipe.title).font(.heading).lineLimit(2).multilineTextAlignment(.leading)
                        StepTicks(recipe: recipe)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 18).contentShape(Rectangle())
            }
            .buttonStyle(PressRow())
            Button(action: start) {
                ZStack {
                    Circle().strokeBorder(Color.ink, lineWidth: Metric.hairline)
                    if cooking { OrbitDot(radius: 24) }
                    LucideIcon(.play, size: 16).offset(x: 1)
                }
                .frame(width: 48, height: 48).contentShape(Circle())
            }
            .buttonStyle(Ripple())
            .accessibilityLabel(cooking ? "Continue \(recipe.title)" : "Cook \(recipe.title)")
            .disabled(!recipe.isUsable).opacity(recipe.isUsable ? 1 : 0.3)
        }
    }
}

/// One short hairline per step; a step with a timer stands taller.
struct StepTicks: View {
    let recipe: Recipe
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(recipe.steps.prefix(24).enumerated()), id: \.offset) { _, step in
                    Capsule().fill(Color.ink).frame(width: Metric.hairline, height: DurationFinder.find(in: step).isEmpty ? 7 : 14)
                }
            }
            Text(recipe.summary).font(.caption).foregroundStyle(Color.muted).lineLimit(1)
        }
        .frame(height: 16, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recipe.summary)
    }
}

/// Every step as a hairline segment: done in ink, the current one in ink too, the rest faint.
struct StepProgress: View {
    let count: Int
    let step: Int
    var finished = false
    var height: CGFloat = 2

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(1, count), id: \.self) { index in
                Capsule().fill(index <= step || finished ? Color.ink : Color.rule)
                    .opacity(index == step && !finished ? 1 : index < step || finished ? 0.45 : 1)
                    .frame(height: height)
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.15), value: step)
        .animation(.standard, value: finished)
        .accessibilityHidden(true)
    }
}

// MARK: A recipe

struct RecipeScreen: View {
    @ObservedObject var store: CookStore
    let recipeID: String
    @Binding var path: [AppRoute]
    @State private var editing = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let recipe = store.recipe(recipeID) { content(recipe) }
            else { Text("This recipe was deleted.").font(.bodyText).foregroundStyle(Color.muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .page()
        .navigationTitle("Recipe").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    menuItem("Edit", .pencil) { editing = true }
                    menuItem("Delete", .trash2, role: .destructive) { confirmDelete = true }
                } label: {
                    LucideIcon(.ellipsis, size: 20).frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .accessibilityLabel("More")
            }
        }
        .sheet(isPresented: $editing) {
            if let recipe = store.recipe(recipeID) { RecipeEditor(store: store, recipe: recipe) { _ in } }
        }
        .confirmationDialog("Delete this recipe?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete recipe", role: .destructive) { store.delete(recipeID); dismiss() }
        }
    }

    private func content(_ recipe: Recipe) -> some View {
        let cooking = store.session?.recipe.id == recipe.id
        return ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(recipe.title).font(.display).tracking(-0.6).fixedSize(horizontal: false, vertical: true)
                    Text(([recipe.yield, recipe.sourceHost].compactMap { $0 } + [recipe.cooked > 0 ? (recipe.cooked == 1 ? "Cooked once" : "Cooked \(recipe.cooked) times") : nil]
                        .compactMap { $0 }).joined(separator: " · "))
                        .font(.caption).foregroundStyle(Color.muted)
                    StepTicks(recipe: recipe)
                }
                if !recipe.ingredients.isEmpty {
                    Block {
                        ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { index, item in
                            if index > 0 { Hairline(delay: 0.03 * Double(index)) }
                            Text(item).font(.bodyText).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                        }
                    } header: { Heading("Ingredients", count: recipe.ingredients.count) }
                }
                Block {
                    ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                        if index > 0 { Hairline(delay: 0.03 * Double(index)) }
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(String(format: "%02d", index + 1))
                                .font(.geist(12, .medium, relativeTo: .caption)).monospacedDigit().foregroundStyle(Color.muted)
                            VStack(alignment: .leading, spacing: 10) {
                                Text(step).font(.bodyText).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                                let durations = DurationFinder.find(in: step)
                                if !durations.isEmpty {
                                    HStack(spacing: 6) { ForEach(durations, id: \.self) { DurationChip(duration: $0) } }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 14)
                    }
                } header: { Heading("Steps", count: recipe.steps.count) }
            }
            .padding(.horizontal, Metric.gutter).padding(.top, 12).padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Rule(inset: 0)
                Button {
                    if !cooking { store.start(recipe) }
                    path.append(.cooking)
                } label: { Text(cooking ? "Continue cooking" : "Start cooking") }
                    .buttonStyle(CapsuleAction(filled: true))
                    .disabled(!recipe.isUsable)
                    .padding(.horizontal, Metric.gutter).padding(.top, 14).padding(.bottom, -8)
            }
            .background(Color.paper)
        }
    }
}

/// "Simmer · 15 min", as a quiet chip under a step.
struct DurationChip: View {
    let duration: StepDuration
    var body: some View {
        HStack(spacing: 5) {
            LucideIcon(.timer, size: 13)
            Text([duration.label, duration.short].compactMap { $0 }.joined(separator: " · ")).font(.caption).monospacedDigit()
        }
        .foregroundStyle(Color.muted)
        .padding(.horizontal, 8).frame(minHeight: 24)
        .overlay(Capsule().strokeBorder(Color.rule, lineWidth: Metric.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timer: \(duration.label ?? "step"), \(duration.short)")
    }
}

// MARK: Editor

/// One page of text. Paste a recipe and it is sorted as you type; paste a link and the
/// page is fetched and its recipe put here as text, ready to correct.
struct RecipeEditor: View {
    @ObservedObject var store: CookStore
    let recipe: Recipe?
    let saved: (Recipe) -> Void
    @State private var text: String
    @State private var source: String?
    @State private var fetching = false
    @State private var problem: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(store: CookStore, recipe: Recipe?, saved: @escaping (Recipe) -> Void) {
        self.store = store; self.recipe = recipe; self.saved = saved
        _text = State(initialValue: recipe?.text ?? "")
        _source = State(initialValue: recipe?.source)
    }

    private var link: URL? { RecipeParser.link(in: text) }
    private var parsed: Recipe { RecipeParser.parse(text) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.bodyText).lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .autocorrectionDisabled()
                        .padding(.horizontal, Metric.gutter - 5)
                        .accessibilityLabel("Recipe text")
                    if text.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Paste a recipe, or a link to one.").font(.heading)
                            Text("Start with its name. Runes sorts out the ingredients and the steps, and every time a step mentions becomes a timer.")
                                .font(.bodyText).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, Metric.gutter).padding(.top, 8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
                .animation(.standard, value: text.isEmpty)
                Rule(inset: 0)
                footer.padding(.horizontal, Metric.gutter).padding(.vertical, 12)
                    .frame(minHeight: 72)
                    .animation(.standard, value: fetching)
            }
            .page()
            .navigationTitle(recipe == nil ? "New recipe" : "Edit recipe").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.font(.label) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).font(.label).disabled(link != nil || !parsed.isUsable)
                }
            }
            .onChange(of: text) { problem = nil }
        }
        .tint(Color.ink)
        .onAppear { if recipe == nil { focused = true } }
    }

    /// One line under the text that says what Runes makes of it, and the one thing to do next.
    @ViewBuilder private var footer: some View {
        if let problem {
            HStack(spacing: 12) {
                Circle().fill(Color.ink).frame(width: 6, height: 6)
                Text(problem).font(.bodyText).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        } else if let link {
            HStack(spacing: 12) {
                LucideIcon(.link, size: 18).foregroundStyle(Color.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.host() ?? "Link").font(.label).lineLimit(1)
                    Text(fetching ? "Reading the page…" : "A link. Runes can read the recipe from it.").font(.caption).foregroundStyle(Color.muted)
                }
                Spacer(minLength: 8)
                Button { fetch(link) } label: {
                    Group { if fetching { ProgressView().tint(Color.paper) } else { Text("Get recipe") } }
                        .font(.label).foregroundStyle(Color.paper)
                        .padding(.horizontal, 14).frame(minWidth: 104, minHeight: 36)
                        .background(Color.ink, in: RoundedRectangle(cornerRadius: Metric.control))
                }
                .buttonStyle(PressRow()).disabled(fetching)
            }
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack {
                Text("Nothing here yet.").font(.caption).foregroundStyle(Color.muted)
                Spacer()
                Button { paste() } label: {
                    HStack(spacing: 8) { LucideIcon(.clipboardPaste, size: 16); Text("Paste") }
                        .font(.label)
                        .padding(.horizontal, 14).frame(minHeight: 36)
                        .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: Metric.hairline))
                }
                .buttonStyle(PressRow())
            }
        } else {
            let recipe = parsed
            HStack(alignment: .center, spacing: 12) {
                LucideIcon(recipe.isUsable ? .check : .info, size: 18).foregroundStyle(recipe.isUsable ? Color.ink : Color.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.isUsable ? recipe.title : "No steps found yet").font(.label).lineLimit(1)
                    Text(recipe.isUsable ? recipe.summary : "Put each step on its own line under a line that says Steps.")
                        .font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
            }
            .animation(.standard, value: recipe.summary)
            .accessibilityElement(children: .combine)
        }
    }

    private func paste() {
        guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else { problem = "The clipboard is empty. Copy a recipe or its link first."; return }
        text = pasted
        if let link = RecipeParser.link(in: pasted) { fetch(link) }
    }

    private func fetch(_ url: URL) {
        guard !fetching else { return }
        fetching = true; problem = nil; focused = false
        Task {
            do {
                let fetched = try await store.fetch(url)
                source = fetched.source
                text = fetched.text
            } catch {
                problem = error.localizedDescription
            }
            fetching = false
        }
    }

    private func save() {
        var result = parsed
        if let recipe { result.id = recipe.id; result.added = recipe.added; result.cooked = recipe.cooked; result.lastCooked = recipe.lastCooked }
        result.source = source
        store.save(result)
        dismiss()
        saved(result)
    }
}

// MARK: Settings

struct CookSettingsScreen: View {
    @ObservedObject var store: CookStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosing: CookCommand?

    private enum Sound: String, CaseIterable { case on = "On", off = "Off" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    Block {
                        ForEach(Array(CookCommand.allCases.enumerated()), id: \.element) { index, command in
                            if index > 0 { Hairline(delay: 0.04 * Double(index)) }
                            TriggerRow(title: command.title, detail: command.detail,
                                       steps: store.controls.trigger(for: command)?.steps) { choosing = command }
                        }
                    } header: {
                        Heading("Gestures")
                    } footer: {
                        Note("A gesture or a combo each. While you cook, they turn the recipe’s pages and run its timers, and mappings that use their gestures are off.")
                    }
                    SwitchControlsBlock()
                    Block {
                        HairlineSegments(selection: Binding(get: { store.sounds ? Sound.on : .off }, set: { store.setSounds($0 == .on) }),
                                         options: Sound.allCases, title: \.rawValue)
                    } header: {
                        Heading("Sounds")
                    } footer: {
                        Note("A tick for each step and a bell when a timer ends, while Runes is open. With the phone locked, a finished timer sends a notification instead.")
                    }
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 40)
            }
            .page()
            .navigationTitle("Cook settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) } }
            .sheet(item: $choosing) { command in
                let current = store.controls.trigger(for: command)
                let others = CookCommand.allCases.filter { $0 != command }
                TriggerSheet(title: command.title, caption: command.detail, rules: CommandTrigger.rules,
                             steps: current?.steps ?? [], intervalMs: current?.intervalMs ?? ComboRules.defaultTime,
                             taken: Set(others.compactMap(store.controls.gesture)),
                             feed: RunesIOSApp.snapshotName == nil ? .shared : nil,
                             note: { steps in
                    others.first { store.controls.trigger(for: $0)?.steps == steps }.map { "\($0.title) uses this; they’ll swap." }
                        ?? (CommandTrigger(steps: steps).usesMotion ? "Rotation, movement and air gestures keep the band’s motion sensors on while you cook, which uses more battery." : nil)
                }, save: { steps, interval in
                    store.setTrigger(steps.isEmpty ? nil : CommandTrigger(steps: steps, intervalMs: interval), for: command)
                })
            }
        }
        .tint(Color.ink)
    }
}
