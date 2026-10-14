import SwiftUI

// Calendar's pieces, from iOS 6.1.3's own (as in Sadhana): the seven calendar
// colours of EventKitUI's `CalendarColors.plist`, MobileCal's banner gradient
// and arrows, UIKit's toolbar and its bar-style segmented control.

// MARK: - Colours

/// The colours iOS 6 gave calendars, in its order: red, orange, yellow,
/// green, blue, purple, brown.
enum CalendarPalette {
    static let colors: [Color] = [
        (185, 14, 40), (246, 79, 0), (230, 200, 0), (68, 167, 3), (14, 97, 185), (113, 26, 118), (136, 47, 0),
    ].map { Color(red: Double($0.0) / 255, green: Double($0.1) / 255, blue: Double($0.2) / 255) }

    /// A topic's colour, the same every time.
    static func color(for topicID: Int) -> Color {
        colors[((topicID % colors.count) + colors.count) % colors.count]
    }
}

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

// MARK: - Toolbar

/// UISegmentedControl in its bar style, as on Calendar's toolbar: blue-grey
/// segments from UIKit's artwork, the chosen one darker, white words.
struct BarSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    let selection: Value
    let onSelect: (Value) -> Void

    private let cap: CGFloat = 6

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                let on = option.value == selection
                if i > 0 {
                    Image.classic(on || options[i - 1].value == selection ? "SegBarDividerSelected" : "SegBarDivider")
                        .resizable()
                        .frame(width: 1)
                }
                Button { onSelect(option.value) } label: {
                    Text(option.title)
                        .font(.helvetica(12, weight: .bold))
                        .engraved()
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background { segment(on ? "SegBarButtonSelected" : "SegBarButton", index: i) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(height: 30)
    }

    /// A segment's slice of the artwork: rounded only at the outer ends.
    private func segment(_ image: String, index: Int) -> some View {
        let first = index == 0, last = index == options.count - 1
        return Image.classic(image, leading: cap, trailing: cap)
            .padding(.leading, first ? 0 : -cap)
            .padding(.trailing, last ? 0 : -cap)
            .clipped()
    }
}

/// UIToolbar: Calendar's blue-grey bar along the foot of the screen.
struct ClassicToolbar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 6)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background { Image.classic("Toolbar").resizable() }
    }
}
