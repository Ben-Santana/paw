import SwiftUI
import UIKit

// The Mac app's look: monochrome, Geist, hairline rules, 6 px controls, 8 px panels,
// no shadows at rest, 200 ms transitions. Dark mode inverts the same five tokens.

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
}

extension Animation {
    /// Control and state transitions.
    static let standard = Animation.easeOut(duration: 0.2)
    /// Screen content arriving.
    static let entrance = Animation.easeOut(duration: 0.35)
}

enum Metric {
    static let control: CGFloat = 6
    static let panel: CGFloat = 8
    static let gutter: CGFloat = 20
    static let hairline: CGFloat = 1
}

// MARK: Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.label)
            .foregroundStyle(Color.paper)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 16)
            .background(Color.ink.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: Metric.control))
            .opacity(enabled ? 1 : 0.45)
            .animation(.standard, value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.label)
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 16)
            .background(configuration.isPressed ? Color.soft : Color.paper, in: RoundedRectangle(cornerRadius: Metric.control))
            .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: Metric.hairline))
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
            .frame(minHeight: 44)
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
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.soft, in: RoundedRectangle(cornerRadius: Metric.panel))
        .overlay(RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.rule, lineWidth: Metric.hairline))
        .accessibilityElement(children: .combine)
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
