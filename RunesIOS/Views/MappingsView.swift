import SwiftUI

// The Mac app's Motions page for iPhone: profiles, one row per gesture, combos, and an
// editor for each mapping's steps and linked actions. Same look as Settings: panels,
// hairline rules, Geist.

// MARK: Page

struct MappingsScreen: View {
    @ObservedObject var store: MappingStore
    var done: () -> Void = {}
    @State private var path: [String] = []
    @State private var renaming: MappingProfile?
    @State private var newName = ""
    @State private var addingProfile = false
    @State private var deleting: MappingProfile?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 28) {
                    profileBar
                    LiveStrip(recent: store.recent)
                    MappingGroup("Gestures") {
                        ForEach(Array(store.active.gestures.enumerated()), id: \.element.id) { index, mapping in
                            if index > 0 { RowDivider() }
                            NavigationLink(value: mapping.id) {
                                MappingRow(mapping: mapping, profiles: store.library.profiles, flashed: flashed(mapping.id))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    MappingGroup("Combos", caption: "Several gestures in a row. A combo owns its gestures, so their own mappings don’t also run.") {
                        ForEach(Array(store.active.combos.enumerated()), id: \.element.id) { index, mapping in
                            NavigationLink(value: mapping.id) {
                                MappingRow(mapping: mapping, title: comboTitle(mapping, index), profiles: store.library.profiles, flashed: flashed(mapping.id))
                            }
                            .buttonStyle(.plain)
                            RowDivider()
                        }
                        Button {
                            let combo = Mapping.newCombo()
                            store.save(combo); path.append(combo.id)
                        } label: {
                            HStack(spacing: 12) {
                                LucideIcon(.plus, size: 18).frame(width: 32)
                                Text("Add combo").font(.bodyText)
                                Spacer()
                            }
                            .padding(.horizontal, 14).frame(minHeight: 52).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Metric.gutter)
            }
            .page()
            .navigationTitle("Mappings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done).font(.label) } }
            .navigationDestination(for: String.self) { id in
                MappingEditor(store: store, mappingID: id, title: title(for: id))
            }
            .alert("Rename profile", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") { if let p = renaming { store.renameProfile(p.id, to: newName) } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("New profile", isPresented: $addingProfile) {
                TextField("Name", text: $newName)
                Button("Add") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    store.addProfile(name: name.isEmpty ? "Profile \(store.library.profiles.count + 1)" : name, icon: MappingProfile.icons[store.library.profiles.count % MappingProfile.icons.count])
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Profiles hold their own mappings. Switch between them here or with a gesture.") }
            .confirmationDialog(deleting.map { "Delete \($0.name)?" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { p in
                Button("Delete profile", role: .destructive) { store.deleteProfile(p.id) }
            } message: { _ in Text("Its gesture mappings and combos are removed from this phone.") }
        }
        .tint(Color.ink)
    }

    private func flashed(_ id: String) -> Bool { store.lastFired?.id == id }
    private func comboTitle(_ mapping: Mapping, _ index: Int) -> String {
        mapping.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Combo \(index + 1)"
    }
    private func title(for id: String) -> String {
        if let kind = GestureKind(rawValue: id) { return kind.name }
        let combos = store.active.combos
        guard let index = combos.firstIndex(where: { $0.id == id }) else { return "Combo" }
        return comboTitle(combos[index], index)
    }

    private var profileBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Profile").padding(.leading, 2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.library.profiles) { profile in
                        let active = profile.id == store.library.activeID
                        Button { store.selectProfile(profile.id) } label: {
                            HStack(spacing: 6) {
                                LucideIcon(Lucide.profile(profile.icon), size: 15)
                                Text(profile.name).font(.label).lineLimit(1)
                            }
                            .padding(.horizontal, 12).frame(minHeight: 36)
                            .foregroundStyle(active ? Color.paper : Color.ink)
                            .background(active ? Color.ink : Color.paper, in: RoundedRectangle(cornerRadius: Metric.control))
                            .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: active ? 0 : Metric.hairline))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(active ? .isSelected : [])
                        .contextMenu {
                            menuItem("Rename", .pencil) { newName = profile.name; renaming = profile }
                            Menu {
                                ForEach(MappingProfile.icons, id: \.self) { icon in
                                    menuItem(icon.capitalized + (icon == profile.icon ? " ✓" : ""), Lucide.profile(icon)) { store.setIcon(profile.id, icon) }
                                }
                            } label: { Label { Text("Icon") } icon: { Lucide.profile(profile.icon).image(size: 18) } }
                            menuItem("Duplicate", .copy) { store.duplicateProfile(profile.id) }
                            if store.library.profiles.count > 1 {
                                menuItem("Delete", .trash2, role: .destructive) { deleting = profile }
                            }
                        }
                    }
                    Button { newName = ""; addingProfile = true } label: {
                        LucideIcon(.plus, size: 16)
                            .frame(width: 36, height: 36)
                            .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: Metric.hairline))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add profile")
                }
                .padding(.vertical, 1)
            }
            Text("Touch and hold a profile to rename, change its icon or delete it.")
                .font(.caption).foregroundStyle(Color.muted).padding(.leading, 2)
        }
    }
}

// MARK: Rows

private struct MappingRow: View {
    let mapping: Mapping
    var title: String?
    let profiles: [MappingProfile]
    var flashed = false

    var body: some View {
        HStack(spacing: 12) {
            if let steps = mapping.steps {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title ?? "Combo").font(.bodyText)
                    StepChips(steps: steps, compact: true)
                    Text(summary).font(.caption).foregroundStyle(Color.muted).lineLimit(1)
                }
            } else if let kind = mapping.motion {
                GestureIcon(gesture: kind, size: 22).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.name).font(.bodyText)
                    Text(summary).font(.caption).foregroundStyle(Color.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Circle().fill(mapping.isLive ? Color.ink : Color.clear).frame(width: 6, height: 6)
                .overlay(Circle().strokeBorder(Color.faint, lineWidth: mapping.isLive ? 0 : 1))
                .accessibilityHidden(true)
            LucideIcon(.chevronRight, size: 16).foregroundStyle(Color.muted)
        }
        .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 52)
        .background(flashed ? Color.soft : Color.clear)
        .animation(.standard, value: flashed)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(mapping.isLive ? "On" : "Off")
    }

    private var summary: String {
        if mapping.actions.isEmpty { return mapping.isCombo && !(mapping.steps.map(ComboRules.valid) ?? false) ? "Add steps and an action" : "Not set" }
        let first = mapping.actions[0].label(profiles: profiles)
        let text = mapping.actions.count == 1 ? first : "\(first) + \(mapping.actions.count - 1) more"
        if !mapping.enabled { return "Off · \(text)" }
        if !mapping.isLive { return "Needs attention · \(text)" }
        return text
    }
}

/// A combo step as the Mac shows it: the gesture icon, plus the axis (and direction) for motion.
struct StepIcon: View {
    let step: ComboStep
    var size: CGFloat = 20
    var body: some View {
        HStack(spacing: 2) {
            GestureIcon(gesture: step.gesture, size: size)
            if let axis = step.axis {
                Text(axis.rawValue.uppercased() + (step.gesture == .rotation ? (step.direction ?? .any).arrow : ""))
                    .font(.geist(max(10, size * 0.6), .medium, relativeTo: .caption2)).foregroundStyle(Color.muted)
            }
        }
        .accessibilityElement().accessibilityLabel(step.name)
    }
}

private struct StepChips: View {
    let steps: [ComboStep]
    var compact = false
    var body: some View {
        if steps.isEmpty {
            Text("No steps yet").font(.caption).foregroundStyle(Color.muted)
        } else {
            FlowLayout(spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 4) {
                        if index > 0 { LucideIcon(.chevronRight, size: 10).foregroundStyle(Color.faint) }
                        StepIcon(step: step, size: compact ? 15 : 18)
                            .padding(.horizontal, 6).frame(minHeight: compact ? 22 : 28)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.rule, lineWidth: Metric.hairline))
                    }
                }
            }
            .accessibilityElement().accessibilityLabel(steps.map(\.name).joined(separator: ", then "))
        }
    }
}

/// The last five gestures; the ones that ran a mapping are filled.
private struct LiveStrip: View {
    let recent: [MappingStore.RecentGesture]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Live").padding(.leading, 2)
            HStack(spacing: 6) {
                if recent.isEmpty {
                    Text("Make a gesture").font(.bodyText).foregroundStyle(Color.muted)
                }
                ForEach(recent) { item in
                    StepIcon(step: item.step, size: 18)
                        .foregroundStyle(item.ranMapping ? Color.paper : Color.ink)
                        .padding(.horizontal, 8).frame(minHeight: 30)
                        .background(item.ranMapping ? Color.ink : Color.paper, in: RoundedRectangle(cornerRadius: Metric.control))
                        .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: Metric.hairline))
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                        .accessibilityLabel(item.step.name + (item.ranMapping ? ", ran a mapping" : ""))
                }
                Spacer(minLength: 0)
            }
            .animation(.standard, value: recent)
            .padding(.horizontal, 14).frame(minHeight: 52)
            .panel()
        }
    }
}

// MARK: Editor

struct MappingEditor: View {
    @ObservedObject var store: MappingStore
    let mappingID: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var editingAction: Int?
    /// The air step whose shape is being edited; the step count means a new step.
    @State private var editingAir: Int?
    @State private var recording = false
    @State private var recordedThrough = 0
    @State private var confirmDelete = false
    /// A change that reuses a gesture a paired Mac already uses, waiting for the person's OK.
    @State private var pendingOverlap: Mapping?
    @ObservedObject private var links = MacLinks.shared

    private var mapping: Mapping? { store.active.mappings.first { $0.id == mappingID } }

    var body: some View {
        Group {
            if let mapping {
                ScrollView {
                    VStack(spacing: 28) {
                        if mapping.isCombo { stepsSection(mapping) }
                        actionsSection(mapping)
                        MappingGroup(nil) {
                            Toggle(isOn: Binding(get: { mapping.enabled }, set: { on in edit { $0.enabled = on } })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("On").font(.bodyText)
                                    Text(liveText(mapping)).font(.caption).foregroundStyle(Color.muted)
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            RowDivider()
                            Button { store.run(mapping.actions) } label: {
                                Label { Text("Run now") } icon: { LucideIcon(.play, size: 18) }.font(.bodyText)
                                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                    .padding(.horizontal, 14).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(mapping.actions.isEmpty || mapping.actions.contains { $0.problem != nil })
                            RowDivider()
                            Button(role: .destructive) { confirmDelete = true } label: {
                                Text(mapping.isCombo ? "Delete combo" : "Clear mapping").font(.bodyText)
                                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                    .padding(.horizontal, 14).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!mapping.isCombo && mapping.actions.isEmpty)
                        }
                    }
                    .padding(Metric.gutter)
                }
                .sheet(item: Binding(get: { editingAction.map(EditingIndex.init) }, set: { editingAction = $0?.id })) { item in
                    if item.id < mapping.actions.count {
                        ActionEditor(action: mapping.actions[item.id], profiles: store.library.profiles, activeProfileID: store.library.activeID) { updated in
                            edit { $0.actions[item.id] = updated }
                        }
                    }
                }
                .sheet(item: Binding(get: { editingAir.map(EditingIndex.init) }, set: { editingAir = $0?.id })) { item in
                    let steps = mapping.steps ?? []
                    AirGestureEditor(store: store, initial: steps.indices.contains(item.id) ? steps[item.id].air : nil) { shape in
                        edit { m in
                            var steps = m.steps ?? []
                            if steps.indices.contains(item.id) { steps[item.id] = .airShape(shape) }
                            else if steps.count < ComboRules.steps.upperBound { steps.append(.airShape(shape)) }
                            m.steps = steps
                        }
                    }
                }
                .alert("Already used on your Mac", isPresented: Binding(get: { pendingOverlap != nil && editingAction == nil },
                                                                     set: { if !$0 { pendingOverlap = nil } })) {
                    Button("Set anyway") { if let m = pendingOverlap { store.save(m) }; pendingOverlap = nil }
                    Button("Cancel", role: .cancel) { pendingOverlap = nil }
                } message: {
                    Text(overlapText(pendingOverlap))
                }
                .confirmationDialog(mapping.isCombo ? "Delete this combo?" : "Clear this mapping?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button(mapping.isCombo ? "Delete combo" : "Clear mapping", role: .destructive) {
                        store.remove(mappingID: mappingID); dismiss()
                    }
                }
            } else {
                Text("This mapping was removed.").font(.bodyText).foregroundStyle(Color.muted)
            }
        }
        .page()
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .onChange(of: store.recent) { _, recent in record(recent) }
        .onDisappear {
            stopRecording()
            // An untouched new combo leaves no empty row behind.
            if let mapping, mapping.isCombo, mapping.steps?.isEmpty ?? true, mapping.actions.isEmpty { store.remove(mappingID: mappingID) }
        }
    }

    private struct EditingIndex: Identifiable { let id: Int }

    private func edit(_ change: (inout Mapping) -> Void) {
        guard var m = mapping else { return }
        change(&m)
        // A newly completed single mapping turns itself on, as on the Mac.
        if !m.isCombo, mapping?.actions.isEmpty == true, !m.actions.isEmpty { m.enabled = true }
        if let old = mapping, !macOverlaps(old, m).isEmpty { pendingOverlap = m; return }
        store.save(m)
    }

    /// What paired Macs already do with this gesture, when this change newly makes it do something here.
    private func macOverlaps(_ old: Mapping, _ m: Mapping) -> [(mac: String, binding: RelayWire.Binding)] {
        guard m.enabled, m.hasActions else { return [] }
        if let steps = m.steps, !ComboRules.valid(steps) { return [] }
        let unchanged = old.enabled && old.hasActions && old.trigger == m.trigger && old.actions == m.actions
        return unchanged ? [] : links.macUses(m.trigger)
    }

    private func overlapText(_ m: Mapping?) -> String {
        guard let m else { return "" }
        let name = m.steps.map { _ in "This combo" } ?? (m.motion?.name ?? "This gesture")
        let lines = links.macUses(m.trigger).map { "On \($0.mac), it’s set to “\($0.binding.action)” in the \($0.binding.profile) profile." }
        return "\(name) is already used on your Mac. " + Set(lines).sorted().joined(separator: " ") + " Both will run when you make it."
    }

    private func liveText(_ m: Mapping) -> String {
        if m.isLive { return m.actions.contains { $0.kind.needsForeground } ? "Runs when you make it. Opening apps needs Runes on screen." : "Runs when you make it, also while your phone is locked." }
        if m.actions.isEmpty { return "Add an action first." }
        if let steps = m.steps, let problem = ComboRules.problem(steps) { return problem }
        if m.actions.contains(where: { $0.problem != nil }) { return "Finish the highlighted action." }
        return "Turned off."
    }

    // MARK: Steps

    @ViewBuilder private func stepsSection(_ mapping: Mapping) -> some View {
        let steps = mapping.steps ?? []
        MappingGroup("Steps", caption: ComboRules.problem(steps) ?? (mapping.usesMotion
            ? "Make them in this order. While a finger is held there’s no time limit. Rotation, movement and air gestures turn on the band’s motion sensors while this combo is on, which uses more battery."
            : "Make them in this order. While a finger is held there’s no time limit.")) {
            TextField("Combo name (optional)", text: Binding(get: { mapping.name ?? "" }, set: { text in edit { $0.name = text.isEmpty ? nil : String(text.prefix(40)) } }))
                .font(.bodyText).padding(.horizontal, 14).frame(minHeight: 48)
            RowDivider()
            VStack(alignment: .leading, spacing: 10) {
                if steps.isEmpty {
                    Text(recording ? "Make the gestures on your band…" : "Add steps below, or record them from your band.")
                        .font(.bodyText).foregroundStyle(Color.muted)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            Menu {
                                Text(step.name)
                                if step.gesture.isMotion {
                                    Picker("Axis", selection: Binding(get: { step.axis ?? .x }, set: { axis in edit { $0.steps?[index].axis = axis } })) {
                                        ForEach(Axis.allCases, id: \.self) { Text("Axis \($0.rawValue.uppercased())").tag($0) }
                                    }
                                    .pickerStyle(.menu)
                                }
                                if step.gesture == .rotation {
                                    Picker("Direction", selection: Binding(get: { step.direction ?? .any }, set: { d in edit { $0.steps?[index].direction = d } })) {
                                        Text("← Left").tag(RotationDirection.left)
                                        Text("→ Right").tag(RotationDirection.right)
                                        Text("↔ Either way").tag(RotationDirection.any)
                                    }
                                    .pickerStyle(.menu)
                                }
                                if step.gesture.isAir { menuItem("Edit shape", .pencil) { editingAir = index } }
                                if index > 0 { menuItem("Move earlier", .arrowLeft) { moveStep(index, by: -1) } }
                                if index < steps.count - 1 { menuItem("Move later", .arrowRight) { moveStep(index, by: 1) } }
                                menuItem("Remove", .trash2, role: .destructive) { edit { $0.steps?.remove(at: index) } }
                            } label: {
                                HStack(spacing: 6) {
                                    Text("\(index + 1)").font(.caption).foregroundStyle(Color.muted).monospacedDigit()
                                    StepIcon(step: step, size: 18)
                                    Text(step.shortName).font(.label)
                                }
                                .padding(.horizontal, 10).frame(minHeight: 36)
                                .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: Metric.hairline))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Step \(index + 1), \(step.name)")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            RowDivider()
            HStack(spacing: 0) {
                Menu {
                    let allowed = ComboRules.allowedNext(after: steps)
                    ForEach(["index", "middle"], id: \.self) { finger in
                        Section(finger == "index" ? "Index finger" : "Middle finger") {
                            ForEach(allowed.filter { $0.finger == finger }, id: \.self) { kind in
                                menuItem(kind.shortName, gesture: kind) { edit { $0.steps = (($0.steps ?? []) + [ComboStep(kind)]) } }
                            }
                        }
                    }
                    Section("Swipe") {
                        ForEach(allowed.filter { $0.finger == nil && !$0.isMotion }, id: \.self) { kind in
                            menuItem(kind.name, gesture: kind) { edit { $0.steps = (($0.steps ?? []) + [ComboStep(kind)]) } }
                        }
                    }
                    Section("Motion") {
                        menuItem("Rotation", gesture: .rotation) { edit { $0.steps = (($0.steps ?? []) + [.rotation(.x)]) } }
                        menuItem("Movement", gesture: .movement) { edit { $0.steps = (($0.steps ?? []) + [.movement(.x)]) } }
                        if allowed.contains(.air) { menuItem("Air gesture", gesture: .air) { editingAir = steps.count } }
                    }
                } label: {
                    Label { Text("Add step") } icon: { LucideIcon(.plus, size: 18) }.font(.bodyText)
                        .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                }
                .disabled(steps.count >= ComboRules.steps.upperBound)
                Rectangle().fill(Color.rule).frame(width: Metric.hairline).padding(.vertical, 10)
                Button { recording ? stopRecording() : startRecording() } label: {
                    Label { Text(recording ? "Stop" : "Record") } icon: { LucideIcon(recording ? .x : .circleDot, size: 18) }.font(.bodyText)
                        .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            RowDivider()
            HStack {
                Text("Time between steps").font(.bodyText)
                Spacer()
                Picker("Time between steps", selection: Binding(get: { mapping.intervalMs ?? ComboRules.defaultTime }, set: { ms in edit { $0.intervalMs = ms } })) {
                    ForEach(ComboRules.times, id: \.self) { ms in Text(ms < 1000 ? "\(ms) ms" : String(format: ms % 1000 == 0 ? "%.0f s" : "%.1f s", Double(ms) / 1000)).tag(ms) }
                }
                .labelsHidden().font(.bodyText)
            }
            .padding(.leading, 14).padding(.trailing, 4).frame(minHeight: 48)
        }
    }

    private func moveStep(_ index: Int, by offset: Int) {
        edit { m in
            guard var steps = m.steps, steps.indices.contains(index + offset) else { return }
            steps.swapAt(index, index + offset)
            m.steps = steps
        }
    }

    private func startRecording() {
        recordedThrough = store.recent.last?.id ?? 0
        store.paused = true
        recording = true
    }
    private func stopRecording() {
        guard recording else { return }
        recording = false
        store.paused = false
    }
    /// Appends each new band gesture as a step, skipping any that would break hold order.
    private func record(_ recent: [MappingStore.RecentGesture]) {
        guard recording else { return }
        // Motion is set by hand (axis, direction); only taps, holds and swipes are recorded.
        let new = recent.filter { $0.id > recordedThrough && !$0.gesture.isMotion && !$0.gesture.isAir }
        recordedThrough = recent.last?.id ?? recordedThrough
        for item in new {
            edit { m in
                var steps = m.steps ?? []
                guard steps.count < ComboRules.steps.upperBound, ComboRules.allowedNext(after: steps).contains(item.gesture) else { return }
                steps.append(item.step); m.steps = steps
            }
        }
        if (mapping?.steps?.count ?? 0) >= ComboRules.steps.upperBound { stopRecording() }
    }

    // MARK: Actions

    @ViewBuilder private func actionsSection(_ mapping: Mapping) -> some View {
        let caption = mapping.actions.count > 1 ? "Runs in order, each after the one before finishes." : "Add more than one to link them together."
        MappingGroup(mapping.actions.count > 1 ? "Actions" : "Action", caption: caption) {
            ForEach(Array(mapping.actions.enumerated()), id: \.offset) { index, action in
                HStack(spacing: 12) {
                    Button { editingAction = index } label: {
                        HStack(spacing: 12) {
                            Text("\(index + 1)").font(.caption).foregroundStyle(Color.muted).monospacedDigit().frame(width: 14)
                            LucideIcon(action.icon(profiles: store.library.profiles), size: 20).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.label(profiles: store.library.profiles)).font(.bodyText).lineLimit(1)
                                if let problem = action.problem {
                                    Text(problem).font(.caption).foregroundStyle(Color.ink).underline()
                                } else if action.kind.needsForeground {
                                    Text("Needs Runes on screen").font(.caption).foregroundStyle(Color.muted)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Menu {
                        if index > 0 { menuItem("Move up", .arrowUp) { edit { $0.actions.swapAt(index, index - 1) } } }
                        if index < mapping.actions.count - 1 { menuItem("Move down", .arrowDown) { edit { $0.actions.swapAt(index, index + 1) } } }
                        if mapping.actions.count < ComboRules.actions.upperBound {
                            menuItem("Duplicate", .copy) { edit { $0.actions.insert(action, at: index + 1) } }
                        }
                        menuItem("Remove", .trash2, role: .destructive) { edit { $0.actions.remove(at: index) } }
                    } label: {
                        LucideIcon(.ellipsis, size: 18).frame(width: 36, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("More for action \(index + 1)")
                }
                .padding(.leading, 14).padding(.trailing, 4).frame(minHeight: 52)
                RowDivider()
            }
            Menu {
                ForEach(["Apps", "Send", "Feedback & timing", "Profiles"], id: \.self) { group in
                    Section(group) {
                        ForEach(MappingAction.Kind.allCases.filter { $0.group == group }) { kind in
                            menuItem(kind.title, kind.icon) { add(kind) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    LucideIcon(.plus, size: 18).frame(width: 36)
                    Text(mapping.actions.isEmpty ? "Choose an action" : "Add another action").font(.bodyText)
                    Spacer()
                }
                .padding(.horizontal, 14).frame(minHeight: 52).contentShape(Rectangle())
            }
            .disabled(mapping.actions.count >= ComboRules.actions.upperBound)
        }
    }

    private func add(_ kind: MappingAction.Kind) {
        var action = kind.template
        if kind == .changeProfile, let other = store.library.profiles.first(where: { $0.id != store.library.activeID }) ?? store.library.profiles.first {
            action = .changeProfile(other.id)
        }
        if kind == .notify || kind == .spotify { store.requestNotificationPermission() }
        let index = mapping?.actions.count ?? 0
        edit { $0.actions.append(action) }
        // Fill in anything that needs text right away.
        if action.problem != nil { editingAction = index }
    }
}

// MARK: Action editor

private struct ActionEditor: View {
    @State var action: MappingAction
    let profiles: [MappingProfile]
    let activeProfileID: String
    let save: (MappingAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var headers: [Header] = []
    @ObservedObject private var spotify = SpotifyClient.shared

    struct Header: Identifiable, Hashable { let id = UUID(); var name: String; var value: String }

    init(action: MappingAction, profiles: [MappingProfile], activeProfileID: String, save: @escaping (MappingAction) -> Void) {
        _action = State(initialValue: action)
        self.profiles = profiles; self.activeProfileID = activeProfileID; self.save = save
        if case .apiCall(_, _, let h, _, _) = action {
            _headers = State(initialValue: h.sorted { $0.key < $1.key }.map { Header(name: $0.key, value: $0.value) })
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    fields
                    if let problem = current.problem {
                        Text(problem).font(.caption).foregroundStyle(Color.muted)
                    } else if action.kind.needsForeground {
                        Text("Runs only while Runes is on screen. iPhone doesn’t let apps open other apps from the background.")
                            .font(.caption).foregroundStyle(Color.muted)
                    }
                }
                .padding(Metric.gutter)
            }
            .page()
            .navigationTitle(action.kind.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.font(.label) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save(current); dismiss() }.font(.label) }
            }
        }
        .tint(Color.ink)
    }

    /// The action with header rows folded back in.
    private var current: MappingAction {
        guard case .apiCall(let method, let url, _, let body, let timeout) = action else { return action }
        let pairs = headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { ($0.name.trimmingCharacters(in: .whitespaces), $0.value) }
        return .apiCall(method: method, url: url.trimmingCharacters(in: .whitespaces), headers: Dictionary(pairs, uniquingKeysWith: { $1 }), body: body, timeoutMs: timeout)
    }

    @ViewBuilder private var fields: some View {
        switch action {
        case .runShortcut(let name):
            field("Shortcut name", "Exactly as it appears in Shortcuts") {
                TextField("My shortcut", text: Binding(get: { name }, set: { action = .runShortcut($0) }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        case .openURL(let url):
            field("Link", "A web address, or an app link such as music:// or maps://") {
                TextField("https://", text: Binding(get: { url }, set: { action = .openURL($0) }))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        case .apiCall(let method, let url, _, let body, let timeout):
            field("Method", nil) {
                Picker("Method", selection: Binding(get: { method }, set: { action = .apiCall(method: $0, url: url, headers: [:], body: $0 == .GET ? "" : body, timeoutMs: timeout) })) {
                    ForEach(HTTPMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            field("URL", nil) {
                TextField("https://example.com/hook", text: Binding(get: { url }, set: { action = .apiCall(method: method, url: $0, headers: [:], body: body, timeoutMs: timeout) }))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Headers")
                VStack(spacing: 0) {
                    ForEach($headers) { $header in
                        HStack(spacing: 8) {
                            TextField("Name", text: $header.name).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Rectangle().fill(Color.rule).frame(width: Metric.hairline, height: 24)
                            TextField("Value", text: $header.value).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button { headers.removeAll { $0.id == header.id } } label: { LucideIcon(.x, size: 16).foregroundStyle(Color.muted).frame(width: 28, height: 36) }
                                .buttonStyle(.plain).accessibilityLabel("Remove header")
                        }
                        .font(.bodyText).padding(.horizontal, 14).frame(minHeight: 44)
                        RowDivider()
                    }
                    Button { headers.append(Header(name: "", value: "")) } label: {
                        Label { Text("Add header") } icon: { LucideIcon(.plus, size: 18) }.font(.bodyText).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 14).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .panel()
            }
            if method != .GET {
                field("Body", nil) {
                    TextEditor(text: Binding(get: { body }, set: { action = .apiCall(method: method, url: url, headers: [:], body: $0, timeoutMs: timeout) }))
                        .font(.system(.footnote, design: .monospaced)).frame(minHeight: 110).scrollContentBackground(.hidden)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            field("Timeout", nil) {
                Stepper("\(timeout / 1000) seconds", value: Binding(get: { timeout / 1000 }, set: { action = .apiCall(method: method, url: url, headers: [:], body: body, timeoutMs: $0 * 1000) }), in: 1...120)
                    .font(.bodyText)
            }
        case .notify(let title, let body):
            field("Title", nil) { TextField("Runes", text: Binding(get: { title }, set: { action = .notify(title: $0, body: body) })) }
            field("Message", "Shown even while your phone is locked") { TextField("Message", text: Binding(get: { body }, set: { action = .notify(title: title, body: $0) }), axis: .vertical) }
        case .copyText(let text):
            field("Text", nil) { TextField("Text to copy", text: Binding(get: { text }, set: { action = .copyText($0) }), axis: .vertical) }
        case .haptic(let style):
            field("Feel", nil) {
                Picker("Feel", selection: Binding(get: { style }, set: { action = .haptic($0) })) {
                    ForEach(HapticStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        case .wait(let ms):
            field("Duration", "Pauses before the next linked action") {
                Stepper(String(format: "%.1f seconds", Double(ms) / 1000), value: Binding(get: { ms }, set: { action = .wait(ms: $0) }), in: 100...30_000, step: 100)
                    .font(.bodyText)
            }
        case .changeProfile(let id):
            field("Profile", nil) {
                Picker("Profile", selection: Binding(get: { id }, set: { action = .changeProfile($0) })) {
                    ForEach(profiles) { p in Label { Text(p.name) } icon: { Lucide.profile(p.icon).image(size: 18) }.tag(p.id) }
                }
                .pickerStyle(.inline).labelsHidden()
            }
        case .spotify(let command):
            field("Command", "Controls whatever Spotify is playing on any device, even while your phone is locked") {
                Picker("Command", selection: Binding(get: { command }, set: { action = .spotify($0) })) {
                    ForEach(SpotifyCommand.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline).labelsHidden()
            }
            SpotifyAccountSection(client: spotify)
        case .moveProfile(let direction):
            field("Direction", "Moves through profiles in the order shown on the Mappings page") {
                Picker("Direction", selection: Binding(get: { direction }, set: { action = .moveProfile($0) })) {
                    Text("Previous").tag(ProfileDirection.up)
                    Text("Next").tag(ProfileDirection.down)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func field<Content: View>(_ title: String, _ hint: String?, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            content().font(.bodyText).padding(.horizontal, 14).padding(.vertical, 12).panel()
            if let hint { Text(hint).font(.caption).foregroundStyle(Color.muted) }
        }
    }
}

/// Sign-in for Spotify actions: the person's own Spotify app client ID, then OAuth.
private struct SpotifyAccountSection: View {
    @ObservedObject var client: SpotifyClient
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Spotify account")
            VStack(alignment: .leading, spacing: 0) {
                if client.isConnected {
                    HStack {
                        LucideIcon(.check, size: 18)
                        Text("Connected\(client.accountName.map { " as \($0)" } ?? "")").font(.bodyText).lineLimit(1)
                        Spacer()
                        Button("Disconnect") { client.disconnect() }.font(.label)
                    }
                    .padding(.horizontal, 14).frame(minHeight: 48)
                } else {
                    Button {
                        working = true; error = nil
                        Task {
                            do { try await client.connect() } catch { self.error = error.localizedDescription }
                            working = false
                        }
                    } label: {
                        HStack { Text(working ? "Connecting…" : "Connect Spotify").font(.bodyText); Spacer(); LucideIcon(.chevronRight, size: 16) }
                            .padding(.horizontal, 14).frame(minHeight: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(working)
                }
            }
            .panel()
            if let error { Text(error).font(.caption).foregroundStyle(Color.ink) }
            if !client.isConnected {
                Text("Playback control needs Spotify Premium.").font(.caption).foregroundStyle(Color.muted)
            }
        }
    }
}

// MARK: Building blocks

struct MappingGroup<Content: View>: View {
    let title: String?
    var caption: String?
    @ViewBuilder var content: Content
    init(_ title: String?, caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.caption = caption; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { SectionLabel(title).padding(.leading, 2) }
            VStack(spacing: 0) { content }.panel()
            if let caption { Text(caption).font(.caption).foregroundStyle(Color.muted).padding(.leading, 2).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct RowDivider: View {
    var body: some View { Rectangle().fill(Color.rule).frame(height: Metric.hairline).padding(.leading, 14) }
}

/// Wraps chips onto as many lines as they need.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if next > width, !current.items.isEmpty { rows.append(current); current = ([index], size.width, size.height) }
            else { current = (current.items + [index], next, max(current.height, size.height)) }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: Icons (the Mac app's)

/// A menu row with a Lucide icon, as menus only take an `Image`.
@MainActor func menuItem(_ title: String, _ icon: Lucide, role: ButtonRole? = nil, _ action: @escaping () -> Void) -> some View {
    Button(role: role, action: action) { Label { Text(title) } icon: { icon.image(size: 18) } }
}
/// A menu row with the Mac's gesture icon.
@MainActor func menuItem(_ title: String, gesture: GestureKind, _ action: @escaping () -> Void) -> some View {
    Button(action: action) { Label { Text(title) } icon: { GestureIcon.image(gesture, size: 18) } }
}

extension Lucide {
    /// The Mac's profile icon keys (MenuIcons.tsx `profileIcons`).
    static func profile(_ key: String) -> Lucide {
        switch key {
        case "work": .briefcase
        case "code": .codeXml
        case "music": .music
        case "game": .gamepad2
        case "camera": .camera
        case "design": .penTool
        case "globe": .globe
        case "star": .star
        case "heart": .heart
        case "monitor": .monitor
        case "headphones": .headphones
        default: .house
        }
    }
}

extension MappingAction.Kind {
    /// Mac OutputIcon where the Mac has the action; Lucide's nearest otherwise.
    var icon: Lucide {
        switch self {
        case .runShortcut: .layers        // Mac "Open Apple Shortcuts"
        case .openURL: .appWindow         // Mac "Open an app"
        case .apiCall: .earth             // Mac Globe2
        case .notify: .bell
        case .copyText: .clipboardCopy
        case .haptic: .vibrate
        case .wait: .hourglass
        case .changeProfile: .house
        case .moveProfile: .arrowDown
        case .spotify: .music
        }
    }
}

extension MappingAction {
    func icon(profiles: [MappingProfile]) -> Lucide {
        switch self {
        case .changeProfile(let id): Lucide.profile(profiles.first { $0.id == id }?.icon ?? "home")
        case .moveProfile(let direction): direction == .up ? .arrowUp : .arrowDown
        case .spotify(.next): .skipForward
        case .spotify(.play), .spotify(.playPause): .play
        case .spotify(.pause): .square
        case .spotify(.saveTrack): .heart
        case .spotify(.toggleShuffle), .spotify(.cycleRepeat): .rotateCcw
        default: kind.icon
        }
    }
}
