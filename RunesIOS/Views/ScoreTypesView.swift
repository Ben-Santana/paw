import SwiftUI

// Game types: what a point is worth towards a win. Free play counts with no end; tennis,
// table tennis and the other sports know their games and sets; and the user can make
// their own (first to a number, by any lead, over a number of games). Opened from the
// trophy in the score screen's bar. The rules themselves are `ScoreRules` in ScoreModel.

struct GameTypeScreen: View {
    @ObservedObject var store: ScoreStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: EditedType?
    /// A type chosen while a score is on the board, waiting to be confirmed.
    @State private var pending: ScoreRules?

    /// `creating` opens straight on a new type, for previews.
    init(store: ScoreStore, creating: Bool = false) {
        self.store = store
        _editing = State(initialValue: creating ? EditedType(rules: nil) : nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        ChoiceList(options: ScoreRules.presets + store.types, selected: store.game.rules, label: { type in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.name).font(.bodyText)
                                Text(type.detail).font(.caption).foregroundStyle(Color.muted)
                            }
                            .padding(.vertical, 6)
                        }, choose: choose)
                        Text("Choosing another type starts everyone from zero. A game or match that is won can be taken back with the winner’s minus.")
                            .font(.caption).foregroundStyle(Color.muted).padding(.horizontal, 2).fixedSize(horizontal: false, vertical: true)
                    }
                    PanelGroup("Your game types", caption: "First to a number of points, by any lead, over as many games as you like.") {
                        ForEach(store.types) { type in
                            ActionRow(type.name, icon: .pencil) { editing = EditedType(rules: type) }
                                .accessibilityHint("Changes or deletes this game type.")
                            Rule()
                        }
                        ActionRow("New game type", icon: .plus) { editing = EditedType(rules: nil) }
                    }
                }
                .padding(Metric.gutter)
            }
            .page()
            .navigationTitle("Game type").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) } }
            .sheet(item: $editing) { edited in
                GameTypeSheet(existing: edited.rules, save: { store.saveType($0) },
                              delete: { if let id = edited.rules?.id { store.deleteType(id) } })
            }
            .confirmationDialog("Change to \(pending?.name ?? "")?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible, presenting: pending) { type in
                Button("Change game type", role: .destructive) { store.play(type); dismiss() }
            } message: { _ in Text("Everyone goes back to zero.") }
        }
        .tint(Color.ink)
    }

    private func choose(_ type: ScoreRules) {
        if type == store.game.rules { dismiss() }
        else if store.game.isEmpty { store.play(type); dismiss() }
        else { pending = type }
    }
}

/// The custom type being made (nil) or changed.
private struct EditedType: Identifiable {
    let rules: ScoreRules?
    var id: String { rules?.id ?? "new" }
}

/// Makes or changes one of the user's own game types.
private struct GameTypeSheet: View {
    let existing: ScoreRules?
    let save: (ScoreRules) -> Void
    let delete: () -> Void
    @State private var name: String
    @State private var points: Int
    @State private var winBy: Int
    @State private var games: Int
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private static let pointChoices = [3, 5, 7, 9, 10, 11, 15, 21, 25, 30, 40, 50, 100]

    init(existing: ScoreRules?, save: @escaping (ScoreRules) -> Void, delete: @escaping () -> Void) {
        self.existing = existing; self.save = save; self.delete = delete
        _name = State(initialValue: existing?.name ?? "")
        _points = State(initialValue: existing?.points ?? 11)
        _winBy = State(initialValue: existing?.winBy ?? 1)
        _games = State(initialValue: existing?.games ?? 1)
    }

    /// The type as it would be saved; a changed type keeps its id.
    private var rules: ScoreRules {
        if let existing { return .custom(id: existing.id, name: name, points: points, winBy: winBy, games: games) }
        return .custom(name: name, points: points, winBy: winBy, games: games)
    }
    private var named: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        FormSheet(existing == nil ? "New game type" : "Game type", canSave: named, save: { save(rules) }) {
            VStack(alignment: .leading, spacing: 24) {
                TitleField(prompt: "Name", text: $name, focus: $focused)
                    .onChange(of: name) { _, new in
                        if new.count > ScoreRules.nameLimit { name = String(new.prefix(ScoreRules.nameLimit)) }
                    }
                field("Points to win a game") {
                    ChipRow(selection: $points, options: (Self.pointChoices + [points]).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }.sorted()) { "\($0)" }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Win by")
                    WinByControl(lead: $winBy, points: points)
                }
                field("Games to win the match") {
                    ChipRow(selection: $games, options: Array(1...7)) { "\($0)" }
                }
                Text(rules.detail).font(.bodyText).foregroundStyle(Color.muted)
                    .contentTransition(.opacity).animation(.standard, value: rules.detail)
                if existing != nil {
                    Button("Delete game type") { dismiss(); delete() }.buttonStyle(.secondary)
                }
            }
        }
        .onAppear { focused = existing == nil }
        // The lead is never more than the points themselves.
        .onChange(of: points) { _, new in winBy = min(winBy, new) }
    }

    /// A caption over a row of chips, which runs to the sheet's edges.
    private func field(_ title: String, @ViewBuilder chips: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            chips().padding(.horizontal, -Metric.inset)
        }
    }
}

/// The lead a game is won by, drawn as the closest score it can end on: the winner's tile
/// on the target, the runner-up's as near as the rules let them get, and the gap between
/// them. Dragging sideways pulls the two apart or together, a point at a time; the minus
/// and plus do the same. Any lead from one point up to the points themselves.
private struct WinByControl: View {
    @Binding var lead: Int
    let points: Int
    /// The lead when the drag began.
    @State private var dragFrom: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let tile: CGFloat = 64
    private var most: Int { max(1, points) }
    private func set(_ value: Int) { lead = min(max(value, 1), most) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                step(.minus, by: -1, label: "Smaller lead")
                GeometryReader { geo in
                    // The gap opens quickly for the first few points and then eases, so a
                    // lead of two reads at a glance and a lead of twenty still fits.
                    let room = max(20, geo.size.width - Self.tile * 2)
                    let gap = 20 + (room - 20) * (1 - exp(-Double(lead - 1) / 3))
                    HStack(spacing: 0) {
                        face(points, tint: 0)
                        VStack(spacing: 3) {
                            Text("\(lead)").font(.label).monospacedDigit().fixedSize()
                                .contentTransition(.numericText(value: Double(lead)))
                            HStack(spacing: 0) {
                                Rectangle().frame(width: 1.5, height: 9)
                                Rectangle().frame(height: 1.5)
                                Rectangle().frame(width: 1.5, height: 9)
                            }
                            .padding(.horizontal, 4)
                        }
                        .frame(width: gap).offset(y: -9)
                        face(points - lead, tint: 1)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .frame(height: Self.tile)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        let from = dragFrom ?? lead
                        dragFrom = from
                        set(from + Int((value.translation.width / 18).rounded()))
                    }
                    .onEnded { _ in dragFrom = nil })
                step(.plus, by: 1, label: "Bigger lead")
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.3), value: lead)
            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.3), value: points)
            Text(caption).font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
        }
        .sensoryFeedback(.selection, trigger: lead)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Win by")
        .accessibilityValue(lead == 1 ? "1 point" : "\(lead) points")
        .accessibilityHint(caption)
        .accessibilityAdjustableAction { set(lead + ($0 == .increment ? 1 : -1)) }
    }

    private var caption: String {
        if lead == 1 { return "The first to \(points) wins, however close. Drag the scores apart to ask for a bigger lead." }
        return "The closest a game can end is \(points)–\(points - lead). Any closer and play goes on until someone is \(lead) ahead."
    }

    /// A score in a player's colour, as on the board.
    private func face(_ score: Int, tint: Int) -> some View {
        Text("\(max(0, score))")
            .font(.geist(score > 99 ? 22 : 30, .semibold, relativeTo: .title)).monospacedDigit()
            .contentTransition(.numericText(value: Double(score)))
            .foregroundStyle(ScoreTint.ink(tint))
            .frame(width: Self.tile, height: Self.tile)
            .background(ScoreTint.fill(tint), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func step(_ icon: Lucide, by delta: Int, label: String) -> some View {
        let off = delta < 0 ? lead <= 1 : lead >= most
        return Button { set(lead + delta) } label: {
            ZStack {
                Circle().strokeBorder(Color.rule, lineWidth: Metric.hairline).frame(width: 36, height: 36)
                LucideIcon(icon, size: 16)
            }
            .frame(width: Metric.tap, height: Metric.tap).contentShape(Rectangle())
        }
        .buttonStyle(Ripple())
        .buttonRepeatBehavior(.enabled)
        .disabled(off).opacity(off ? 0.3 : 1)
        .accessibilityLabel(label)
    }
}

#if DEBUG
#Preview("Game types") { GameTypeScreen(store: ScoreStore(preview: PreviewFixtures.tennis())) }
#Preview("Game types · new") { GameTypeScreen(store: ScoreStore(preview: PreviewFixtures.tennis()), creating: true) }
#endif
