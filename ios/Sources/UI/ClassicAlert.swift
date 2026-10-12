import SwiftUI

// iOS 6's UIAlertView: the screen dims around a soft spotlight and a glossy
// navy panel pops in with a bounce — a bold title, the message, and one or two
// buttons side by side. Drawn from UIKit's own artwork.

/// One button of an alert. The default one (the right-hand one) wears the
/// lighter bezel.
struct AlertButton {
    let title: String
    var isDefault = false
    var action: () -> Void = {}
}

/// The app's one alert at a time, shown by `AlertHost` at the root.
@MainActor
final class Alerts: ObservableObject {
    static let shared = Alerts()

    struct Alert: Identifiable {
        let id = UUID()
        let title: String
        let message: String?
        let buttons: [AlertButton]
    }

    @Published private(set) var current: Alert?

    func show(_ title: String, message: String? = nil,
              _ buttons: [AlertButton] = [AlertButton(title: "OK", isDefault: true)]) {
        withAnimation(.easeOut(duration: 0.2)) {
            current = Alert(title: title, message: message, buttons: buttons)
        }
    }

    func dismiss() {
        withAnimation(.easeIn(duration: 0.2)) { current = nil }
    }
}

/// Hosts the alert over the whole window. Attach once, at the root.
struct AlertHost: View {
    @ObservedObject private var alerts = Alerts.shared

    var body: some View {
        ZStack {
            if let alert = alerts.current {
                Image.classic("AlertDimming")
                    .resizable()
                    .ignoresSafeArea()
                    // Taps don't reach the screen below; an alert must be answered.
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .transition(.opacity)
                AlertPanel(alert: alert) { button in
                    alerts.dismiss()
                    button.action()
                }
                .id(alert.id)
                .transition(.opacity)
            }
        }
    }
}

private struct AlertPanel: View {
    let alert: Alerts.Alert
    let finish: (AlertButton) -> Void

    @State private var scale: CGFloat = 0.01

    var body: some View {
        VStack(spacing: 0) {
            Text(alert.title)
                .font(.helvetica(18, weight: .bold))
            if let message = alert.message {
                Text(message)
                    .font(.helvetica(16))
                    .padding(.top, 8)
            }
            HStack(spacing: 10) {
                ForEach(alert.buttons.indices, id: \.self) { i in
                    let button = alert.buttons[i]
                    Button(button.title) { finish(button) }
                        .buttonStyle(AlertButtonStyle(isDefault: button.isDefault))
                }
            }
            .padding(.top, 16)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 0, x: 0, y: -1)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(width: 284)
        .background {
            Image.classic("AlertBackground", top: 30, leading: 14, bottom: 30, trailing: 14)
        }
        .scaleEffect(scale)
        // UIAlertView's pop: overshoot, settle back under, then rest.
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) { scale = 1.1 } completion: {
                withAnimation(.easeInOut(duration: 0.1)) { scale = 0.9 } completion: {
                    withAnimation(.easeInOut(duration: 0.1)) { scale = 1 }
                }
            }
        }
        .accessibilityAddTraits(.isModal)
    }
}

/// The alert's buttons: a pale-rimmed bezel, lit for the default one, darkened
/// under the finger.
private struct AlertButtonStyle: ButtonStyle {
    let isDefault: Bool

    func makeBody(configuration: Configuration) -> some View {
        let image = configuration.isPressed ? "AlertButtonPressed"
            : isDefault ? "AlertDefaultButton" : "AlertButton"
        return configuration.label
            .font(.helvetica(18, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 43)
            .background { Image.classic(image, leading: 5, trailing: 5) }
            .contentShape(Rectangle())
    }
}
