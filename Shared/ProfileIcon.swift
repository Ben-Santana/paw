import SwiftUI

/// Profile icons, keyed the same as the Mac (MenuIcons.tsx `profileIcons`), in picker order.
/// Shared with the Live Activity so it can show the active profile's icon.
enum ProfileIcon {
    /// The Runes mark, Lucide "hand".
    static let logo = "runes"
    static let fallback = "home"

    static let all: [(key: String, label: String, paths: [String])] = [
        (logo, "Runes", LucideData.hand),
        ("home", "Home", LucideData.house),
        ("work", "Work", LucideData.briefcase),
        ("code", "Code", LucideData.codeXml),
        ("terminal", "Terminal", LucideData.terminal),
        ("monitor", "Monitor", LucideData.monitor),
        ("keyboard", "Keyboard", LucideData.keyboard),
        ("chart", "Chart", LucideData.chartLine),
        ("presentation", "Presentation", LucideData.presentation),
        ("book", "Book", LucideData.bookOpen),
        ("school", "School", LucideData.graduationCap),
        ("chat", "Chat", LucideData.messageCircle),
        ("mail", "Mail", LucideData.mail),
        ("music", "Music", LucideData.music),
        ("headphones", "Headphones", LucideData.headphones),
        ("mic", "Microphone", LucideData.mic),
        ("video", "Video", LucideData.video),
        ("tv", "TV", LucideData.tv),
        ("game", "Game", LucideData.gamepad2),
        ("camera", "Camera", LucideData.camera),
        ("design", "Design", LucideData.penTool),
        ("palette", "Palette", LucideData.palette),
        ("globe", "Globe", LucideData.globe),
        ("plane", "Travel", LucideData.plane),
        ("car", "Car", LucideData.car),
        ("bike", "Bike", LucideData.bike),
        ("fitness", "Fitness", LucideData.dumbbell),
        ("run", "Run", LucideData.footprints),
        ("coffee", "Coffee", LucideData.coffee),
        ("moon", "Night", LucideData.moon),
        ("sun", "Day", LucideData.sun),
        ("leaf", "Nature", LucideData.leaf),
        ("paw", "Pets", LucideData.pawPrint),
        ("rocket", "Rocket", LucideData.rocket),
        ("star", "Star", LucideData.star),
        ("heart", "Heart", LucideData.heart),
    ]
    static let keys = all.map(\.key)
    private static let byKey = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    static func paths(_ key: String) -> [String] { byKey[key]?.paths ?? byKey[fallback]!.paths }
    static func label(_ key: String) -> String { byKey[key]?.label ?? "Profile" }
    static func path(_ key: String) -> Path {
        var combined = Path()
        for d in paths(key) { combined.addPath(SVGPath.cached(d)) }
        return combined
    }
}

/// A profile icon as a plain stroked shape, so it renders in widgets and Live Activities too.
struct ProfileGlyph: View {
    let key: String
    var lineWidth: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let k = min(geo.size.width, geo.size.height) / 24
            ProfileIcon.path(key)
                .applying(CGAffineTransform(scaleX: k, y: k))
                .stroke(style: StrokeStyle(lineWidth: lineWidth * k, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(ProfileIcon.label(key))
    }
}
