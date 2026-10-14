import SwiftUI

// Calendar's pieces, from iOS 6.1.3's own (as in Sadhana): MobileCal's
// banner gradient and arrows.

// MARK: - Banner

/// MobileCal's banner: the light grey gradient strip under the bar that
/// names the day or month, with Calendar's grey arrows either side.
struct CalendarBanner<Title: View>: View {
    var canStepForward = true
    let step: (Int) -> Void
    @ViewBuilder var title: Title

    var body: some View {
        HStack(spacing: 0) {
            arrow("CalArrowLeft", label: String(localized: "Previous")) { step(-1) }
            title
                .frame(maxWidth: .infinity)
            arrow("CalArrowRight", label: String(localized: "Next")) { step(1) }
                .disabled(!canStepForward)
                .opacity(canStepForward ? 1 : 0.35)
        }
        .frame(height: 44)
        .background { Image.classic("CalBanner").resizable() }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.rgb(0x8E949D)).frame(height: 1) }
        .environment(\.colorScheme, .light)
    }

    private func arrow(_ image: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image.classic(image).frame(width: 54, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

extension View {
    /// Words on Calendar's banner: dark slate, a white edge below.
    func bannerInk() -> some View {
        foregroundStyle(Palette.rgb(0x2E3440)).shadow(color: .white, radius: 0, x: 0, y: 1)
    }
}
