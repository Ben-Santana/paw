import SwiftUI
import UIKit

// MARK: Swipe to delete

/// Swipe a row left to reveal a red delete square with a bin on it. Past the square the row
/// resists more and more, so it only goes so far; let go far enough out (or fling it) and the
/// square swells to fill the gap, the row slides away and the rows below close up.
///
/// The gesture locks to its first direction: a vertical drag scrolls the list and never nudges
/// the row, and a horizontal drag never scrolls. A swipe never opens the row, and while a row is
/// open a tap closes it.
///
/// `confirms` is for callers that ask first: the row closes and `onDelete` runs, with no
/// slide-away, so the caller can show its dialog.
struct SwipeToDelete: ViewModifier {
    var confirms = false
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var settled: CGFloat = 0
    @State private var width: CGFloat = 360
    @State private var dragging = false
    @State private var removing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let square: CGFloat = Metric.tap
    private static let gap: CGFloat = 10
    /// How far the row slides to show the square: the square with a gap each side.
    private static let reveal: CGFloat = square + gap * 2

    /// Extra travel past the square before resistance stops it.
    private var stretch: CGFloat { max(80, width * 0.35) }
    /// Letting go beyond this deletes.
    private var deleteAt: CGFloat { Self.reveal + stretch * 0.45 }
    private var committed: Bool { -offset >= deleteAt }
    /// 0 closed → 1 square fully shown.
    private var progress: CGFloat { min(1, max(0, -offset / Self.reveal)) }

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            content
                .offset(x: offset)
                // Mid-swipe and while open, the row's own taps are off, so letting go doesn't open it.
                .allowsHitTesting(!dragging && settled == 0 && !removing)
                .overlay {
                    // While open, a tap on the row closes it instead of opening it.
                    if settled != 0 { Color.clear.contentShape(Rectangle()).onTapGesture { close() } }
                }
            square
        }
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .gesture(HorizontalPan(
            changed: { x in
                guard !removing else { return }
                dragging = true
                offset = resisted(settled + x)
            },
            ended: { velocity in
                dragging = false
                guard !removing else { return }
                if committed || (velocity < -700 && -offset > Self.reveal * 0.6) { delete() }
                else if -offset > Self.reveal / 2 || (velocity < -300 && settled == 0) { snap(-Self.reveal) }
                else { close() }
            },
            cancelled: {
                dragging = false
                if !removing { snap(settled) }
            }
        ))
        .accessibilityAction(named: "Delete", onDelete)
        .sensoryFeedback(.impact(weight: .light), trigger: settled) { _, now in now != 0 }
        .sensoryFeedback(.impact(weight: .medium), trigger: committed) { _, now in now }
    }

    /// The red square, centred in the gap the row leaves. Past the delete point it stretches to
    /// fill the whole gap, which is the cue that letting go deletes.
    private var square: some View {
        let revealed = -offset
        let full = committed && !confirms
        return Button(action: delete) {
            RoundedRectangle(cornerRadius: Metric.control, style: .continuous)
                .fill(Color.destructive)
                .frame(width: full ? max(Self.square, revealed - Self.gap * 2) : Self.square, height: Self.square)
                .overlay(alignment: full ? .trailing : .center) {
                    LucideIcon(.trash2, size: 18, lineWidth: 1.75)
                        .foregroundStyle(.white)
                        .frame(width: Self.square, height: Self.square)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, Self.gap)
        // Follows the row out past the square so it stays centred, until it swells to fill.
        .offset(x: full ? 0 : min(0, (offset + Self.reveal) / 2))
        .scaleEffect(0.7 + 0.3 * progress)
        .opacity(removing ? 0 : progress)
        .animation(.spring(duration: 0.3, bounce: 0.15), value: full)
        .allowsHitTesting(progress > 0.5 && !removing && !dragging)
        .accessibilityHidden(true)
    }

    /// Free up to the square, then rubber-banded so it approaches `reveal + stretch` and no further.
    /// Rightward drags barely move.
    private func resisted(_ x: CGFloat) -> CGFloat {
        if x > 0 { return x * 0.15 }
        let distance = -x
        guard distance > Self.reveal else { return x }
        let over = distance - Self.reveal
        return -(Self.reveal + stretch * (1 - 1 / (over / stretch * 0.8 + 1)))
    }

    private func snap(_ x: CGFloat) {
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { offset = x }
        settled = x
    }
    private func close() { snap(0) }

    private func delete() {
        if confirms {
            close()
            onDelete()
            return
        }
        removing = true
        let out = reduceMotion ? 0 : 0.2
        withAnimation(.easeIn(duration: out)) { offset = -(width + Self.reveal) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(out))
            // The rows below slide up into the space.
            withAnimation(.spring(duration: 0.35, bounce: 0.1)) { onDelete() }
            // If the row's identity outlives the item (index-keyed lists), it shows the next one closed.
            var still = Transaction(); still.disablesAnimations = true
            withTransaction(still) { offset = 0; settled = 0; removing = false }
        }
    }
}

extension View {
    /// Swipe left to delete; the row slides away on its own.
    func swipeToDelete(_ onDelete: @escaping () -> Void) -> some View {
        modifier(SwipeToDelete(onDelete: onDelete))
    }
    /// Swipe left to delete, where `onDelete` asks first: the row closes and the caller shows its dialog.
    func swipeToDelete(confirms: Bool, _ onDelete: @escaping () -> Void) -> some View {
        modifier(SwipeToDelete(confirms: confirms, onDelete: onDelete))
    }
}

// MARK: Gesture

/// A pan that decides its direction in the first few points. Vertical fails at once, so the
/// enclosing scroll view (which waits for it) scrolls as normal; horizontal begins, and the scroll
/// view then stays put for the rest of the touch.
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void
    let cancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> DirectionLockedPan {
        let pan = DirectionLockedPan()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: DirectionLockedPan, context: Context) {
        switch pan.state {
        case .changed: changed(pan.translation(in: pan.view).x)
        case .ended: ended(pan.velocity(in: pan.view).x)
        case .cancelled, .failed: cancelled()
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// The list's scroll waits for this pan to fail, which a vertical drag does within a few points.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}

final class DirectionLockedPan: UIPanGestureRecognizer {
    private var start: CGPoint?
    /// Movement before the direction is judged; small, so scrolling is never held up noticeably.
    private let decideAt: CGFloat = 6

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if start == nil { start = touches.first?.location(in: nil) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let start, let now = touches.first?.location(in: nil) {
            let dx = now.x - start.x, dy = now.y - start.y
            guard dx * dx + dy * dy >= decideAt * decideAt else { return }
            if abs(dy) > abs(dx) { state = .failed; return }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        super.reset()
        start = nil
    }
}
