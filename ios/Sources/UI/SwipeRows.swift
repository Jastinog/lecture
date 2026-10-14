import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// iOS 6 swipe-to-delete and edit mode. A quick horizontal stroke across a row
// (either way) brings up a red "Delete" on its right edge; the row's text makes
// room and its disclosure arrow fades out. Only one row of a list shows it at a
// time; tapping a row or scrolling puts it away. In edit mode each row grows a
// red minus on the left, and tapping it turns the bar upright and offers the same
// button.

/// The swipe button's colour. Red deletes; blue is for the reversible ones.
enum RowSwipeTint {
    case red, blue

}

extension View {
    /// Gives a list row iOS 6's swipe button (and, in edit mode, the red minus).
    /// `id` tells the rows apart, so only one shows its button. The list needs
    /// `classicSwipeList()`.
    func classicSwipeButton(_ title: String = String(localized: "Delete"), id: some Hashable, tint: RowSwipeTint = .red,
                            action: @escaping () -> Void) -> some View {
        modifier(ClassicSwipeRow(id: AnyHashable(id), title: title, tint: tint, action: action))
    }

    /// Apply to a list whose rows use `classicSwipeButton`: it keeps which row is
    /// open, and scrolling or leaving edit mode puts the button away.
    @ViewBuilder
    func classicSwipeList() -> some View {
        modifier(ClassicSwipeList())
    }
}

extension EnvironmentValues {
    /// True while the row's swipe button or edit control is out: the disclosure
    /// arrow steps aside, as a cell's accessory did.
    @Entry var rowAccessoryHidden = false
}

private struct ClassicSwipeRow: ViewModifier {
    let id: AnyHashable
    let title: String
    let tint: RowSwipeTint
    let action: () -> Void

    @Environment(\.rowSwipe) private var swipe
    @Environment(\.editMode) private var editMode

    func body(content: Content) -> some View {
        if let swipe {
            let editing = editMode?.wrappedValue.isEditing == true
            let shown = swipe.revealed == id
            content
                .environment(\.rowAccessoryHidden, shown || editing)
                // While a button is out (or in edit mode) a tap on a row only
                // puts it away; it doesn't open anything.
                .overlay {
                    if editing || swipe.revealed != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { swipe.set(nil) }
                    }
                }
                // Beside the row rather than in a stack with it, so the row's
                // own list insets and separator still reach the list.
                .safeAreaInset(edge: .trailing, spacing: 0) {
                    Button(title) {
                        swipe.set(nil)
                        action()
                    }
                    .buttonStyle(RowSwipeButtonStyle(tint: tint))
                    .fixedSize()
                    .padding(.leading, 6)
                    // It unrolls leftwards from the row's edge.
                    .frame(width: shown ? nil : 0, alignment: .trailing)
                    .clipped()
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
                }
                .padding(.leading, editing ? RemoveControl.width : 0)
                .overlay(alignment: .leading) {
                    if editing {
                        RemoveControl(turned: shown) { swipe.toggle(id) }
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .gesture(RowStroke { if !editing { swipe.toggle(id) } })
                .accessibilityAction(named: title) { action() }
        } else {
            content
        }
    }
}

/// Which row of a list has its button out: one at a time, as in UITableView.
@Observable
final class RowSwipeState {
    private(set) var revealed: AnyHashable?

    func toggle(_ id: AnyHashable) { set(revealed == id ? nil : id) }

    func set(_ id: AnyHashable?) {
        guard id != revealed else { return }
        withAnimation(.easeInOut(duration: 0.3)) { revealed = id }
    }
}

extension EnvironmentValues {
    /// The list's swipe state; rows outside a `classicSwipeList()` get no swipe.
    @Entry var rowSwipe: RowSwipeState? = nil
}

private struct ClassicSwipeList: ViewModifier {
    @State private var swipe = RowSwipeState()
    @Environment(\.editMode) private var editMode

    func body(content: Content) -> some View {
        content
            .environment(\.rowSwipe, swipe)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { swipe.set(nil) }
            }
            .onChange(of: editMode?.wrappedValue) { _, _ in swipe.set(nil) }
    }
}

/// UITableView's delete-confirmation button: the glossy red bezel, white
/// engraved title.
private struct RowSwipeButtonStyle: ButtonStyle {
    let tint: RowSwipeTint

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.helvetica(15, weight: .bold))
            .engraved()
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minWidth: 64)
            .frame(height: 34)
            .background { bezel(pressed: configuration.isPressed) }
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func bezel(pressed: Bool) -> some View {
        let image = Image.classic(pressed ? "DeleteButtonPressed" : "DeleteButton", leading: 8, trailing: 8)
        switch tint {
        case .red: image
        // No blue original exists; the red bezel turned blue.
        case .blue: image.hueRotation(.degrees(218))
        }
    }
}

/// The edit-mode minus: UIKit's red disc with a white bar that turns upright
/// while the row's "Delete" is out.
private struct RemoveControl: View {
    static let width: CGFloat = 38

    let turned: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image.classic("RemoveControl")
                .overlay {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white)
                        .frame(width: 13, height: 4)
                        .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: -1)
                        .rotationEffect(.degrees(turned ? -90 : 0))
                        // The disc's shadow sits below it; centre the bar on the disc.
                        .offset(y: -0.5)
                }
                .frame(width: Self.width, height: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete")
    }
}

/// UITableView's swipe trigger: a quick, mostly horizontal stroke over a row.
/// A vertical drag fails it at once, so the list scrolls as usual (and waits for
/// it); strokes starting at the screen's left edge are left to swipe-back.
private struct RowStroke: UIGestureRecognizerRepresentable {
    let onStroke: () -> Void

    func makeUIGestureRecognizer(context: Context) -> Recognizer { Recognizer() }

    func handleUIGestureRecognizerAction(_ recognizer: Recognizer, context: Context) {
        if recognizer.state == .ended { onStroke() }
    }

    final class Recognizer: UIGestureRecognizer {
        private var start: CGPoint?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard start == nil, touches.count == 1, let touch = touches.first else {
                state = .failed
                return
            }
            let point = touch.location(in: nil)
            start = point
            if point.x < 30 { state = .failed }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard state == .possible, let start, let touch = touches.first else { return }
            let point = touch.location(in: nil)
            let dx = abs(point.x - start.x), dy = abs(point.y - start.y)
            if dy > 4 && dy >= dx {
                state = .failed
            } else if dx > 12 && dx > dy * 2 {
                state = .recognized
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            if state == .possible { state = .failed }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            if state == .possible { state = .failed }
        }

        override func reset() {
            start = nil
        }

        /// The list's own pan waits until the stroke has failed.
        override func shouldBeRequiredToFail(by other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}
