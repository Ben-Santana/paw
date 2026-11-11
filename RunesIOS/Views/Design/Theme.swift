import SwiftUI
import UIKit

// The Mac app's look: monochrome, Geist, hairline rules, 6 px controls, 8 px panels,
// no shadows at rest, 200 ms transitions. Dark mode inverts the same tokens.
// The full guide is Documentation/StyleGuide.md; its live form is Views/Design/StyleGuide.swift.

extension Color {
    private static func token(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
    /// Page background.
    static let paper = token(0xFFFFFF, 0x0B0B0C)
    /// Text and primary marks.
    static let ink = token(0x191919, 0xEDEDED)
    /// Secondary text. 5.6:1 on white, 6.4:1 on the dark page.
    static let muted = token(0x696969, 0x8E8E8E)
    /// Hairline rules and panel borders.
    static let rule = token(0xE8E8E8, 0x262628)
    /// Quiet fills: pressed rows, segmented backgrounds.
    static let soft = token(0xFAFAFA, 0x141416)
    /// Resting electrode strokes on the ring.
    static let faint = token(0xC9C9C9, 0x55555A)
    static let wristGlow = token(0x2979FF, 0x78A7FF)
    /// The one colour: a destructive control that is about to remove something.
    static let destructive = Color(uiColor: .systemRed)
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Geist, bundled under the SIL Open Font License (Resources/Fonts/OFL.txt).
/// Every style scales with Dynamic Type through its `relativeTo` text style.
extension Font {
    static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        let name = switch weight {
        case .medium: "Geist-Medium"
        case .semibold, .bold, .heavy, .black: "Geist-SemiBold"
        default: "Geist-Regular"
        }
        return .custom(name, size: size, relativeTo: style)
    }
    static let display = geist(28, .medium, relativeTo: .largeTitle)
    static let heading = geist(20, .medium, relativeTo: .title3)
    static let bodyText = geist(15, relativeTo: .body)
    static let label = geist(14, .medium, relativeTo: .subheadline)
    static let caption = geist(12, relativeTo: .caption)
    /// Raw values and request bodies only.
    static let code = Font.system(.footnote, design: .monospaced)
}

extension Animation {
    /// Control and state transitions.
    static let standard = Animation.easeOut(duration: 0.2)
    /// Screen content arriving.
    static let entrance = Animation.easeOut(duration: 0.35)
    /// Press feedback on round and capsule controls.
    static let lively = Animation.spring(duration: 0.3, bounce: 0.3)
}

/// See Documentation/StyleGuide.md §4.
enum Metric {
    static let hairline: CGFloat = 1
    /// Step chips and tiny badges.
    static let chip: CGFloat = 4
    /// Buttons, segments, pills.
    static let control: CGFloat = 6
    /// Panels, cards, tiles.
    static let panel: CGFloat = 8
    /// Page side padding.
    static let gutter: CGFloat = 20
    /// Horizontal padding inside a panel row.
    static let inset: CGFloat = 14
    /// Key/value detail rows.
    static let rowDense: CGFloat = 44
    /// Standard rows and buttons.
    static let row: CGFloat = 48
    /// Rows with a two-line label or an icon.
    static let rowTall: CGFloat = 52
    /// Minimum hit target; icon buttons are tap × tap.
    static let tap: CGFloat = 44
}

// MARK: Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.label)
            .foregroundStyle(Color.paper)
            .frame(maxWidth: .infinity, minHeight: Metric.row)
            .padding(.horizontal, 16)
            .background(Color.ink.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: Metric.control))
            .opacity(enabled ? 1 : 0.45)
            .animation(.standard, value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.label)
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity, minHeight: Metric.row)
            .padding(.horizontal, 16)
            .background(configuration.isPressed ? Color.soft : Color.paper, in: RoundedRectangle(cornerRadius: Metric.control))
            .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(selected ? Color.ink : Color.rule, lineWidth: Metric.hairline))
            .opacity(enabled ? 1 : 0.45)
            .animation(.standard, value: configuration.isPressed)
    }
}

/// Text-only action, for secondary choices under a primary button.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.label)
            .foregroundStyle(Color.muted)
            .frame(minHeight: Metric.tap)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.standard, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle { static var primary: PrimaryButtonStyle { .init() } }
extension ButtonStyle where Self == SecondaryButtonStyle { static var secondary: SecondaryButtonStyle { .init() } }
extension ButtonStyle where Self == QuietButtonStyle { static var quiet: QuietButtonStyle { .init() } }

// MARK: Surfaces

struct Panel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.paper, in: RoundedRectangle(cornerRadius: Metric.panel))
            .overlay(RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.rule, lineWidth: Metric.hairline))
    }
}

extension View {
    func panel() -> some View { modifier(Panel()) }
    /// A panel row: inset horizontally, at least `height` tall, tappable across its width.
    func panelRow(height: CGFloat = Metric.row) -> some View {
        self.padding(.horizontal, Metric.inset).frame(maxWidth: .infinity, minHeight: height, alignment: .leading).contentShape(Rectangle())
    }
    /// Page chrome shared by every screen.
    func page() -> some View {
        self.background(Color.paper.ignoresSafeArea())
            .foregroundStyle(Color.ink)
            .tint(Color.ink)
    }
}

/// One plain sentence and one action. Used for every problem the app can show.
struct IssueCard: View {
    let issue: SessionIssue
    let action: (SessionIssue.Action) -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle().fill(issue.isGentle ? Color.muted : Color.ink).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(issue.sentence).font(.bodyText).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(issue.actionTitle) { action(issue.action) }
                .font(.label)
                .padding(.horizontal, 12).frame(minHeight: 36)
                .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: Metric.hairline))
        }
        .padding(.horizontal, Metric.inset).padding(.vertical, 12)
        .background(Color.soft, in: RoundedRectangle(cornerRadius: Metric.panel))
        .overlay(RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.rule, lineWidth: Metric.hairline))
        .accessibilityElement(children: .combine)
    }
}

/// A hairline divider; inset to match the rows it separates.
struct Rule: View {
    var inset: CGFloat = Metric.inset
    init(inset: CGFloat = Metric.inset) { self.inset = inset }
    var body: some View {
        Rectangle().fill(Color.rule).frame(height: Metric.hairline).padding(.leading, inset).accessibilityHidden(true)
    }
}

/// The trailing mark of a row that opens something.
struct Chevron: View {
    var body: some View { LucideIcon(.chevronRight, size: 16).foregroundStyle(Color.muted) }
}

/// A Lucide icon in a 44 × 44 target, for headers and toolbars. Label it where you use it.
struct IconButton: View {
    let icon: Lucide
    var size: CGFloat = 20
    let action: () -> Void
    init(_ icon: Lucide, size: CGFloat = 20, action: @escaping () -> Void) { self.icon = icon; self.size = size; self.action = action }
    var body: some View {
        Button(action: action) {
            LucideIcon(icon, size: size).frame(width: Metric.tap, height: Metric.tap).contentShape(Rectangle())
        }
    }
}

extension UIApplication {
    /// The window's own top safe area (status bar or island), without any navigation bar,
    /// for full-bleed screens that line their top row up with the bar.
    var windowSafeTop: CGFloat {
        connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.top ?? 0
    }
}

/// The leading back chevron for a full-screen cover's root (Settings, Mappings, Applications),
/// so closing it looks like going back from any pushed screen.
struct BackToolbarItem: ToolbarContent {
    let action: () -> Void
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: action) { Image(systemName: "chevron.backward").font(.system(size: 17, weight: .semibold)) }
                .accessibilityLabel("Back")
        }
    }
}

/// A section label, a panel of rows, and an optional caption under it. The one grouping for
/// Settings, Advanced, Mappings and editors.
struct PanelGroup<Content: View>: View {
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
            if let caption {
                Text(caption).font(.caption).foregroundStyle(Color.muted).padding(.horizontal, 2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A key and its value on one panel row.
struct ValueRow<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value
    var height: CGFloat = Metric.row
    init(_ title: String, height: CGFloat = Metric.row, @ViewBuilder value: () -> Value) { self.title = title; self.height = height; self.value = value() }
    var body: some View {
        HStack { Text(title).font(.bodyText); Spacer(); value.font(.bodyText).foregroundStyle(Color.muted) }
            .panelRow(height: height)
            .accessibilityElement(children: .combine)
    }
}

/// A panel row that pushes a destination.
struct LinkRow<Destination: View>: View {
    let title: String
    @ViewBuilder var destination: () -> Destination
    init(_ title: String, @ViewBuilder destination: @escaping () -> Destination) { self.title = title; self.destination = destination }
    var body: some View {
        NavigationLink(destination: destination) {
            HStack { Text(title).font(.bodyText); Spacer(); Chevron() }.panelRow()
        }
        .buttonStyle(.plain)
    }
}

/// A panel row that performs an action, with an optional trailing icon.
struct ActionRow: View {
    let title: String
    var icon: Lucide?
    let action: () -> Void
    init(_ title: String, icon: Lucide? = nil, action: @escaping () -> Void) { self.title = title; self.icon = icon; self.action = action }
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.bodyText)
                Spacer()
                if let icon { LucideIcon(icon, size: 16).foregroundStyle(Color.muted) }
            }
            .panelRow()
        }
        .buttonStyle(.plain)
    }
}

/// Small caps-free section label, as in the Mac app's panel headings.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(Color.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Sheets and choices

/// A small editing sheet: inline title, Cancel, and one confirming action. Content scrolls only
/// when it must.
struct FormSheet<Content: View>: View {
    let title: String
    var done = "Done"
    var canSave = true
    let save: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    init(_ title: String, done: String = "Done", canSave: Bool = true, save: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.done = done; self.canSave = canSave; self.save = save; self.content = content
    }
    var body: some View {
        NavigationStack {
            ScrollView { content().padding(Metric.gutter) }
                .scrollBounceBehavior(.basedOnSize)
                .page()
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.font(.label) }
                    ToolbarItem(placement: .confirmationAction) { Button(done) { save(); dismiss() }.font(.label).disabled(!canSave) }
                }
        }
        .tint(Color.ink)
    }
}

/// Options as panel rows, the chosen one checked. Inline in a form, or inside `ChoiceSheet`.
struct ChoiceList<Value: Hashable, Label: View>: View {
    let options: [Value]
    let selected: Value?
    @ViewBuilder let label: (Value) -> Label
    let choose: (Value) -> Void
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                let on = option == selected
                if index > 0 { Rule() }
                Button { choose(option) } label: {
                    HStack(spacing: 12) {
                        label(option)
                        Spacer(minLength: 8)
                        LucideIcon(.check, size: 16).opacity(on ? 1 : 0).scaleEffect(on ? 1 : 0.6)
                    }
                    .panelRow(height: Metric.rowTall)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .panel()
        .animation(.standard, value: selected)
        .sensoryFeedback(.selection, trigger: selected)
    }
}

/// A medium sheet that asks one question with a list of answers; choosing one closes it.
struct ChoiceSheet<Value: Hashable, Label: View>: View {
    let title: String
    let options: [Value]
    let selected: Value?
    var caption: String? = nil
    @ViewBuilder let label: (Value) -> Label
    let choose: (Value) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ChoiceList(options: options, selected: selected, label: label) { choose($0); dismiss() }
                    if let caption { Text(caption).font(.caption).foregroundStyle(Color.muted).padding(.horizontal, 2) }
                }
                .padding(Metric.gutter)
            }
            .scrollBounceBehavior(.basedOnSize)
            .page()
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.font(.label) } }
        }
        .tint(Color.ink)
        .presentationDetents([.medium, .large])
    }
}

/// Discrete values as a scrolling row of pills, the chosen one in ink; it scrolls to the selection.
struct ChipRow<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        let on = option == selection
                        Button { withAnimation(.standard) { selection = option; reader.scrollTo(option, anchor: .center) } } label: {
                            Text(title(option)).font(.label).monospacedDigit().lineLimit(1)
                                .foregroundStyle(on ? Color.paper : Color.ink)
                                .padding(.horizontal, 12).frame(minHeight: 36)
                                .background(on ? Color.ink : Color.paper, in: RoundedRectangle(cornerRadius: Metric.control))
                                .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: on ? 0 : Metric.hairline))
                        }
                        .buttonStyle(.plain)
                        .id(option)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Metric.inset).padding(.vertical, 1)
            }
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: Metric.inset)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: Metric.inset)
                }
            )
            .onAppear { reader.scrollTo(selection, anchor: .center) }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// A one-line title field in display type, underlined by a rule that wakes with focus.
struct TitleField: View {
    let prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(prompt, text: $text).font(.display).focused(focus).submitLabel(.done)
            FocusRule(active: focus.wrappedValue)
        }
    }
}
