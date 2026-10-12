import SwiftUI

// iOS 6's UIActionSheet: the screen dims, and a translucent slate panel of large
// pill buttons slides up from the bottom edge, with a dark "Cancel" set apart
// at the bottom and destructive choices in red. Drawn from UIKit's own artwork.

/// One button of an action sheet.
struct SheetAction {
    enum Role { case normal, destructive }

    let title: String
    var role = Role.normal
    let action: () -> Void

    static func destructive(_ title: String, action: @escaping () -> Void) -> SheetAction {
        SheetAction(title: title, role: .destructive, action: action)
    }
}

/// The app's one action sheet at a time, shown by `ActionSheetHost` at the root.
@MainActor
final class ActionSheets: ObservableObject {
    static let shared = ActionSheets()

    struct Sheet: Identifiable {
        let id = UUID()
        let title: String?
        let actions: [SheetAction]
    }

    @Published private(set) var current: Sheet?

    /// Slides a sheet up; "Cancel" is added at the bottom.
    func show(_ title: String? = nil, _ actions: [SheetAction]) {
        withAnimation(.easeOut(duration: 0.3)) { current = Sheet(title: title, actions: actions) }
    }

    func dismiss() {
        withAnimation(.easeIn(duration: 0.25)) { current = nil }
    }
}

/// Hosts the action sheet over the whole window. Attach once, at the root.
struct ActionSheetHost: View {
    @ObservedObject private var sheets = ActionSheets.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            if let sheet = sheets.current {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { sheets.dismiss() }
                    .transition(.opacity)
                SheetPanel(sheet: sheet) { action in
                    sheets.dismiss()
                    action?()
                }
                .transition(.move(edge: .bottom))
                .id(sheet.id)
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape) { sheets.dismiss() }
            }
        }
    }
}

private struct SheetPanel: View {
    let sheet: ActionSheets.Sheet
    /// Called with the chosen action, or nil for "Cancel".
    let finish: (((() -> Void))?) -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let title = sheet.title {
                Text(title)
                    .font(.helvetica(13))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 0, x: 0, y: -1)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
            ForEach(sheet.actions.indices, id: \.self) { i in
                let action = sheet.actions[i]
                Button(action.title) { finish(action.action) }
                    .buttonStyle(SheetButtonStyle(kind: action.role == .destructive ? .destructive : .normal))
            }
            Button("Cancel") { finish(nil) }
                .buttonStyle(SheetButtonStyle(kind: .cancel))
                .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, sheet.title == nil ? 20 : 14)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background {
            Image.classic("SheetBackground").resizable()
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// The sheet's pill buttons: light with dark text, red with white for a
/// destructive choice, dark with white for "Cancel".
private struct SheetButtonStyle: ButtonStyle {
    enum Kind { case normal, destructive, cancel }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let image: String
        switch kind {
        case .normal: image = pressed ? "SheetButtonPressed" : "SheetButton"
        case .destructive: image = pressed ? "SheetDestroyButtonPressed" : "SheetDestroyButton"
        // The cancel button has no pressed image; UIKit used the blue one.
        case .cancel: image = pressed ? "SheetButtonPressed" : "SheetCancelButton"
        }
        let light = kind == .normal && !pressed
        return configuration.label
            .font(.helvetica(19, weight: .bold))
            .foregroundStyle(light ? .black : .white)
            .shadow(color: light ? .white.opacity(0.7) : .black.opacity(0.5), radius: 0, x: 0, y: light ? 1 : -1)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background { Image.classic(image, leading: 13, trailing: 13) }
            .contentShape(Rectangle())
    }
}

/// A destructive action confirmed with an action sheet, as iOS 6 confirmed
/// deleting: tapping shows `message` over a red `confirm` button and "Cancel".
struct ConfirmingButton<Label: View>: View {
    var message: String?
    let confirm: String
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    init(_ message: String? = nil, confirm: String, action: @escaping () -> Void,
         @ViewBuilder label: @escaping () -> Label) {
        self.message = message
        self.confirm = confirm
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(role: .destructive) {
            ActionSheets.shared.show(message, [.destructive(confirm, action: action)])
        } label: {
            label()
        }
    }
}
