import SwiftUI
import UIKit

// MARK: Swipe to delete

/// Swipe a row left and a red delete square grows out of the trailing edge with it. Past the
/// square the row resists more and more, so it only goes so far; far enough out the square
/// stretches to fill the gap, and letting go there (or flinging the row) sends it off the edge
/// and the rows below close up.
///
/// The row stays under the finger: it can be caught while it is still moving, and when let go
/// it carries the finger's speed into its spring. One row is open at a time. A touch anywhere
/// else, a scroll, or a swipe on another row closes it, and so does a tap on the row itself.
///
/// The gesture locks to its first direction: a vertical drag scrolls the list and never nudges
/// the row, and a horizontal drag never scrolls. A swipe never opens the row.
///
/// `confirms` is for callers that ask first: the row closes and `onDelete` runs, with no
/// slide-away, so the caller can show its dialog.
struct SwipeToDelete: ViewModifier {
    var confirms = false
    let onDelete: () -> Void

    /// Where the row is, or is heading while it animates.
    @State private var offset: CGFloat = 0
    /// Where it rests: closed, or open on the square.
    @State private var settled: CGFloat = 0
    /// Where the finger would be had it carried the row from closed, when it took hold.
    @State private var grabbed: CGFloat = 0
    @State private var width: CGFloat = 360
    @State private var dragging = false
    /// Far enough out that letting go deletes.
    @State private var armed = false
    @State private var removing = false
    @State private var shown = ShownOffset()
    @State private var id = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    fileprivate static let square: CGFloat = Metric.tap
    fileprivate static let gap: CGFloat = 10
    /// How far the row slides to show the square: the square with a gap each side.
    fileprivate static let reveal: CGFloat = square + gap * 2

    /// Extra travel past the square before resistance stops it.
    private var stretch: CGFloat { max(80, width * 0.35) }
    /// Letting go beyond this deletes.
    private var deleteAt: CGFloat { Self.reveal + stretch * 0.45 }

    func body(content: Content) -> some View {
        content
            .modifier(SwipeTrack(x: offset, filled: armed && !confirms,
                                 // Mid-swipe and while open, the row's own taps are off, so letting go doesn't open it.
                                 rowTaps: !dragging && settled == 0 && !removing,
                                 open: settled != 0 && !dragging && !removing,
                                 shown: shown, close: close, delete: { delete() }))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .gesture(HorizontalPan(
                touched: { OpenSwipe.shared.touched(id, at: $0) },
                began: { window in
                    guard !removing else { return }
                    OpenSwipe.shared.claim(id, in: window, close: close)
                    // Takes the row from wherever it is, even part-way through a spring.
                    grabbed = unresisted(shown.x)
                    dragging = true
                    still { offset = shown.x }
                },
                changed: { x in
                    guard dragging, !removing else { return }
                    offset = resisted(grabbed + x)
                    armed = -offset >= deleteAt
                },
                ended: { velocity in
                    guard dragging else { return }
                    dragging = false
                    guard !removing else { return }
                    let speed = velocity * slope(at: offset)
                    // Where a flick would carry the row if nothing stopped it.
                    let landing = offset + speed * 0.1
                    if armed || (velocity < -700 && -offset > Self.reveal) { delete(speed: speed) }
                    else { settle(landing < -Self.reveal / 2 ? -Self.reveal : 0, speed: speed) }
                },
                cancelled: {
                    guard dragging else { return }
                    dragging = false
                    if !removing { settle(settled) }
                },
                scrolled: { if settled != 0, !removing { close() } }
            ))
            .accessibilityAction(named: "Delete", onDelete)
            .sensoryFeedback(trigger: armed) { _, now in
                now ? .impact(weight: .medium) : dragging ? .impact(weight: .light) : nil
            }
            .onDisappear { OpenSwipe.shared.release(id) }
    }

    /// Free up to the square, then rubber-banded so it approaches `reveal + stretch` and no further.
    /// Rightward drags barely move.
    private func resisted(_ x: CGFloat) -> CGFloat {
        if x > 0 { return x * 0.15 }
        let over = -x - Self.reveal
        guard over > 0 else { return x }
        return -(Self.reveal + stretch * (1 - 1 / (over / stretch * 0.8 + 1)))
    }

    /// The finger position that puts the row at `x`: `resisted` backwards.
    private func unresisted(_ x: CGFloat) -> CGFloat {
        if x > 0 { return x / 0.15 }
        let over = -x - Self.reveal
        guard over > 0 else { return x }
        let left = max(0.05, 1 - over / stretch)
        return -(Self.reveal + (1 / left - 1) * stretch / 0.8)
    }

    /// How much of the finger's speed the row has at `x`; less the more it resists.
    private func slope(at x: CGFloat) -> CGFloat {
        let finger = unresisted(x)
        return (resisted(finger + 1) - resisted(finger - 1)) / 2
    }

    /// A spring to `target` that starts at the speed the row already has, so there is no seam
    /// between the finger letting go and the row coming to rest.
    private func spring(to target: CGFloat, speed: CGFloat, duration: Double) -> Animation? {
        guard !reduceMotion else { return nil }
        let distance = target - offset
        let carried = abs(distance) > 1 ? min(30, max(-12, speed / distance)) : 0
        return .interpolatingSpring(duration: duration, bounce: 0, initialVelocity: carried)
    }

    private func settle(_ target: CGFloat, speed: CGFloat = 0) {
        withAnimation(spring(to: target, speed: speed, duration: 0.35)) { offset = target; armed = false }
        settled = target
        if target == 0 { OpenSwipe.shared.release(id) }
    }
    private func close() { settle(0) }

    private func delete(speed: CGFloat = 0) {
        if confirms {
            close()
            onDelete()
            return
        }
        removing = true
        armed = true
        OpenSwipe.shared.release(id)
        guard !reduceMotion else { return remove() }
        let out = -(width + Self.gap)
        withAnimation(spring(to: out, speed: min(0, speed), duration: 0.28)) { offset = out } completion: { remove() }
    }

    private func remove() {
        // The rows below slide up into the space.
        withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0)) { onDelete() } completion: {
            // Only a row whose identity outlives its item is still here: it shows the next one, closed.
            // Any sooner and the row being removed would jump back into view as it fades.
            still { offset = 0; settled = 0; armed = false; removing = false }
        }
    }

    private func still(_ change: () -> Void) {
        var still = Transaction(); still.disablesAnimations = true
        withTransaction(still, change)
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

// MARK: Drawing

/// Where the row is drawn this frame, which mid-spring is not where it is heading.
private final class ShownOffset {
    var x: CGFloat = 0
}

/// The row and its square at one offset. Animating the offset redraws both from the same number
/// every frame, so the square can never drift from the row.
private struct SwipeTrack: ViewModifier, Animatable {
    var x: CGFloat
    let filled: Bool
    let rowTaps: Bool
    let open: Bool
    let shown: ShownOffset
    let close: () -> Void
    let delete: () -> Void

    var animatableData: CGFloat {
        get { x }
        set { x = newValue }
    }

    func body(content: Content) -> some View {
        let _ = shown.x = x
        ZStack(alignment: .trailing) {
            content
                .offset(x: x)
                .allowsHitTesting(rowTaps)
                .overlay {
                    // While open, a tap on the row closes it instead of opening it.
                    if open { Color.clear.contentShape(Rectangle()).onTapGesture(perform: close) }
                }
            DeleteSquare(revealed: max(0, -x), fill: filled ? 1 : 0, action: delete)
                .animation(.spring(duration: 0.3, bounce: 0.2), value: filled)
                .allowsHitTesting(open)
                .accessibilityHidden(true)
        }
        .clipped()
    }
}

/// The red square, always centred in the gap the row leaves and scaled to it, so it grows out of
/// the edge as the row moves. `fill` stretches it across the whole gap with the bin riding its
/// leading end, which is the cue that letting go deletes; only `fill` animates, so the stretch
/// keeps springing while the finger keeps moving.
private struct DeleteSquare: View, Animatable {
    let revealed: CGFloat
    var fill: CGFloat
    let action: () -> Void

    var animatableData: CGFloat {
        get { fill }
        set { fill = newValue }
    }

    var body: some View {
        let side = SwipeToDelete.square
        let progress = min(1, revealed / SwipeToDelete.reveal)
        let width = side + max(0, (revealed - SwipeToDelete.reveal) * fill)
        Button(action: action) {
            RoundedRectangle(cornerRadius: Metric.control, style: .continuous)
                .fill(Color.destructive)
                .frame(width: width, height: side)
                .overlay(alignment: .leading) {
                    LucideIcon(.trash2, size: 18, lineWidth: 1.75)
                        .foregroundStyle(.white)
                        .frame(width: side, height: side)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(progress)
        .opacity(min(1, progress * 1.5))
        .offset(x: (width - revealed) / 2)
    }
}

// MARK: One open row

/// Keeps one row open at a time. A row claims the place when a finger takes it; whichever row
/// had it closes. While a row is open, a touch that lands anywhere but on it closes it.
@MainActor
private final class OpenSwipe {
    static let shared = OpenSwipe()

    private var owner: UUID?
    private var close: (() -> Void)?
    /// The row the latest touch on a row landed on, and when that touch began.
    private var touchedRow: (id: UUID, at: TimeInterval)?
    private let watched = NSHashTable<UIWindow>.weakObjects()

    func claim(_ id: UUID, in window: UIWindow?, close: @escaping () -> Void) {
        if owner != id { self.close?() }
        owner = id
        self.close = close
        if let window, !watched.contains(window) {
            window.addGestureRecognizer(TouchWatcher { [weak self] in self?.touchBegan(at: $0) })
            watched.add(window)
        }
    }

    func release(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        close = nil
    }

    /// A touch came down on this row.
    func touched(_ id: UUID, at time: TimeInterval) { touchedRow = (id, time) }

    /// A touch came down somewhere in the window. A row hears about the same touch in the same
    /// pass, in no fixed order, so the verdict waits until both have spoken.
    private func touchBegan(at time: TimeInterval) {
        Task { @MainActor in
            guard let owner else { return }
            if let touchedRow, touchedRow.id == owner, touchedRow.at == time { return }
            close?()
        }
    }
}

/// Reports each touch as it lands and then fails, so it never takes a touch from anything.
private final class TouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let touch: (TimeInterval) -> Void

    init(_ touch: @escaping (TimeInterval) -> Void) {
        self.touch = touch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let began = touches.first?.timestamp { touch(began) }
        state = .failed
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

// MARK: Gesture

/// A pan that decides its direction in the first few points. Vertical fails at once, so the
/// enclosing scroll view (which waits for it) scrolls as normal; horizontal begins, and the scroll
/// view then stays put for the rest of the touch.
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let touched: (TimeInterval) -> Void
    let began: (UIWindow?) -> Void
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void
    let cancelled: () -> Void
    let scrolled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> DirectionLockedPan {
        let pan = DirectionLockedPan()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        pan.touched = touched
        pan.scrolled = scrolled
        return pan
    }

    func updateUIGestureRecognizer(_ pan: DirectionLockedPan, context: Context) {
        pan.touched = touched
        pan.scrolled = scrolled
    }

    func handleUIGestureRecognizerAction(_ pan: DirectionLockedPan, context: Context) {
        switch pan.state {
        case .began:
            // Movement counts from here, so the row doesn't jump by the distance it took to decide.
            pan.setTranslation(.zero, in: pan.view)
            began(pan.view?.window)
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
    /// A finger came down on the row, at this time.
    var touched: ((TimeInterval) -> Void)?
    /// The drag turned out to be a scroll.
    var scrolled: (() -> Void)?

    private var start: CGPoint?
    /// Movement before the direction is judged; small, so scrolling is never held up noticeably.
    private let decideAt: CGFloat = 6

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if start == nil {
            start = touches.first?.location(in: nil)
            if let began = touches.first?.timestamp { touched?(began) }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let start, let now = touches.first?.location(in: nil) {
            let dx = now.x - start.x, dy = now.y - start.y
            guard dx * dx + dy * dy >= decideAt * decideAt else { return }
            if abs(dy) > abs(dx) {
                state = .failed
                scrolled?()
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        super.reset()
        start = nil
    }
}
