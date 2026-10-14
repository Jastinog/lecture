import SwiftUI
import CoreGraphics

/// The iOS 6 palette. Light, tactile chrome: blue-grey glossy bars, pinstriped
/// grouped backgrounds, white cells, embossed labels, black glossy tab bar.
///
/// The dark theme (which iOS 6 never had) is its black bar style carried
/// through: black glossy bars, dark grey cells on woven linen, light text.
/// Colours that differ carry both variants and follow the trait.
enum Palette {
    /// Links, values and accent glyphs — the classic table "detail" blue-grey.
    static let accent = rgb(0x385487, dark: 0x8FB2E8)
    /// Bright selection blue (progress fills, selected rows, playing chapter).
    static let selection = Color(red: 0.08, green: 0.42, blue: 0.88)

    /// Row text: black on white cells.
    static let text = rgb(0x000000, dark: 0xE6E6E6)
    /// A row's second line (authors, readers) and running text.
    static let detailText = rgb(0x4C4C4C, dark: 0xB4B4B4)
    static let bodyText = rgb(0x333333, dark: 0xCCCCCC)
    /// Secondary text grey and the hairline between plain rows.
    // A touch darker than iOS 6's 0x808080, to read at WCAG AA (4.5:1) on white.
    static let secondaryText = rgb(0x737373, dark: 0x8C8C8C)
    static let separator = rgb(0xE0E0E0, dark: 0x2E2E2E)
    /// A plain table's cells and backdrop. Black in the dark theme, which is
    /// also what `List` gives the rows it isn't told to colour.
    static let cell = rgb(0xFFFFFF, dark: 0x000000)
    /// A track list's rows, in Music's alternating greys, and its ruling: a
    /// dark line with a light one beside it, between rows and after the number.
    static let trackRow = rgb(0xDFDFDF, dark: 0x1A1A1A)
    static let trackRowAlternate = rgb(0xEAEAEA, dark: 0x232323)
    static let trackRule = rgb(0xC4C4C4, dark: 0x000000)
    static let trackRuleHighlight = rgb(0xF8F8F8, dark: 0x303030)
    /// A grouped table's panel, dark grey on the linen.
    static let panel = rgb(0xFFFFFF, dark: 0x2A2A2A)

    /// Embossed text on pinstripe (group headers, footers, hero labels); on
    /// the dark theme's linen it's light, sunk with a dark edge below.
    static let embossed = rgb(0x4C566C, dark: 0xC9CCD2)
    static let embossedStrong = rgb(0x2C3345, dark: 0xEDEEF0)
    static let embossShadow = shade(UIColor(white: 1, alpha: 0.85), dark: UIColor(white: 0, alpha: 0.7))

    /// The status bar's tint: the bottom colour of the navigation bar image, as
    /// iOS 6 tinted the status bar to match the bar under it.
    static let navBarTint = rgb(0x597498, dark: 0x0D0D0D)

    /// Big blue call-to-action button.
    static let blueButton = Gloss(top: rgb(0x80B5FF), upperMid: rgb(0x3D86F1),
                                  lowerMid: rgb(0x2170E2), bottom: rgb(0x1A62D2))
    /// Progress fill.
    static let progress = Gloss(top: rgb(0x8CC2FF), upperMid: rgb(0x3A85EC),
                                lowerMid: rgb(0x246FDC), bottom: rgb(0x1B5FCC))

    static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    /// A colour with its own shade in the dark theme.
    static func rgb(_ light: UInt32, dark: UInt32) -> Color {
        shade(UIColor(rgb(light)), dark: UIColor(rgb(dark)))
    }

    /// Picks between two colours by the trait; both are built once, up front.
    static func shade(_ light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.isDark ? dark : light })
    }
}

extension UITraitCollection {
    var isDark: Bool { userInterfaceStyle == .dark }
}

// MARK: - Theme

/// The look picked in Settings: light, dark, or whichever the phone uses.
enum AppTheme: String, CaseIterable {
    case light, dark, system

    var title: String {
        switch self {
        case .light:  return String(localized: "Light")
        case .dark:   return String(localized: "Dark")
        case .system: return String(localized: "Automatic")
        }
    }

    var style: UIUserInterfaceStyle {
        switch self {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return .unspecified
        }
    }
}

/// Keeps the picked theme and imposes it on the app's windows, so UIKit's bars
/// and the SwiftUI views under them switch together.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    private static let key = "vuhe.theme"

    @Published var theme: AppTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Self.key)
            apply()
        }
    }

    private init() {
        theme = UserDefaults.standard.string(forKey: Self.key).flatMap(AppTheme.init) ?? .light
    }

    func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = theme.style }
        }
    }
}

/// A four-stop iOS 6 gloss: a lighter upper half and a darker lower half with a
/// hard edge in the middle, which is what gave every bar and button its shine.
struct Gloss {
    let top, upperMid, lowerMid, bottom: Color

    var gradient: LinearGradient {
        LinearGradient(stops: [.init(color: top, location: 0), .init(color: upperMid, location: 0.5),
                               .init(color: lowerMid, location: 0.5), .init(color: bottom, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Original artwork

extension Image {
    /// An original iOS 6.1 image from `Assets.xcassets/Classic` (UIKit, the Music
    /// player and Newsstand), at its natural size.
    static func classic(_ name: String) -> Image {
        Image("Classic/" + name)
    }

    /// An original iOS 6.1 image stretched the way UIKit stretched it: the caps
    /// keep their size and only the strip between them stretches.
    static func classic(_ name: String, top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0,
                        trailing: CGFloat = 0) -> Image {
        Image("Classic/" + name)
            .resizable(capInsets: EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing),
                       resizingMode: .stretch)
    }
}

/// Fills its frame with an image scaled up uniformly (never stretched), cropping
/// the overflow. For textures that would look wrong distorted: linen, wood.
struct AspectFillImage: View {
    let image: Image
    var alignment: Alignment = .center

    var body: some View {
        Color.clear
            .overlay(alignment: alignment) { image.resizable().scaledToFill() }
            .clipped()
            .allowsHitTesting(false)
    }
}

// MARK: - Backgrounds

/// The grouped-table pinstripe; in the dark theme, the woven linen iOS 6 laid
/// under its dark panels (Notification Center).
struct PinstripeBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if scheme == .dark {
            LinenBackground().ignoresSafeArea()
        } else {
            Image.classic("Pinstripe")
                .resizable(resizingMode: .tile)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

/// Dark woven linen with its vignette (behind the Now Playing artwork).
struct LinenBackground: View {
    var body: some View {
        AspectFillImage(image: .classic("Linen"))
    }
}

/// Newsstand's maple, behind the shelves.
struct WoodBackground: View {
    var body: some View {
        Image.classic("ShelfWood")
            .resizable(resizingMode: .tile)
            .allowsHitTesting(false)
    }
}

/// Brushed aluminium (the tape deck face).
struct BrushedMetalBackground: View {
    var body: some View {
        LinearGradient(colors: [Palette.rgb(0xEDEDED), Palette.rgb(0xBDBDBD)],
                       startPoint: .top, endPoint: .bottom)
            .overlay {
                Image(uiImage: Texture.brushed)
                    .resizable(resizingMode: .tile)
                    .blendMode(.overlay)
                    .opacity(0.9)
            }
            .allowsHitTesting(false)
    }
}

/// Generated-once textures for what iOS 6 itself never shipped (the tape deck's
/// metal). Deterministic (fixed seeds) so they're identical every launch and
/// never shimmer when a view redraws.
enum Texture {
    /// Fine horizontal brushing strokes (mid-grey, used with an overlay blend).
    static let brushed: UIImage = {
        let rnd = prng(0x9E3779B97F4A7C15)
        let w = 256, h = 96
        let rows = (0..<h).map { _ in Double(rnd()) / 255 }
        return make(width: w, height: h) { x, y in
            let streak = 0.5 + (rows[y] - 0.5) * 0.35
            let v = streak + (Double(rnd()) / 255 - 0.5) * 0.08
            let g = UInt8(max(0, min(255, v * 255)))
            return (g, g, g)
        }
    }()

    /// Spun aluminium: fine concentric turning marks, 1.1px apart in random
    /// shades, with slower random bands across them and pixel grain (mid-grey,
    /// for an overlay blend).
    static let spun: UIImage = {
        let rnd = prng(0xA24BAED4963EE407)
        let size = 256, c = Double(size) / 2, pitch = 1.1
        let count = Int(c * 1.5 / pitch) + 2
        let ring = (0..<count).map { _ in Double(rnd()) / 255 - 0.5 }
        let knots = (0..<(count / 8 + 2)).map { _ in Double(rnd()) / 255 - 0.5 }
        return make(width: size, height: size) { x, y in
            let d = hypot(Double(x) - c + 0.5, Double(y) - c + 0.5) / pitch
            let i = min(Int(d), count - 1)
            let k = d / 8, k0 = min(Int(k), knots.count - 2), f = k - Double(k0)
            let band = knots[k0] + (knots[k0 + 1] - knots[k0]) * (f * f * (3 - 2 * f))
            let v = 0.5 + ring[i] * 0.32 + band * 0.12 + (Double(rnd()) / 255 - 0.5) * 0.05
            let g = UInt8(max(0, min(255, v * 255)))
            return (g, g, g)
        }
    }()

    /// A pack of wound tape `radius` pixels across from its centre: every turn
    /// a ring one pixel wide in its own shade of oxide brown, nothing blended.
    static func tapePack(radius: Int) -> UIImage {
        let rnd = prng(0x5851F42D4C957F2D)
        let shades = (0...radius + 1).map { _ in Int(rnd() % 15) - 7 }
        let side = radius * 2, c = Double(radius)
        return make(width: side, height: side) { x, y in
            let ring = min(Int(hypot(Double(x) - c + 0.5, Double(y) - c + 0.5)), radius + 1)
            let v = shades[ring]
            return (UInt8(clamping: 60 + v), UInt8(clamping: 38 + v * 2 / 3), UInt8(clamping: 23 + v / 2))
        }
    }

    // xorshift64 — a fast deterministic PRNG.
    private static func prng(_ seed: UInt64) -> () -> UInt8 {
        var s = seed
        return {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return UInt8(truncatingIfNeeded: s >> 24)
        }
    }

    /// Builds an opaque RGB bitmap from a per-pixel colour function.
    private static func make(width: Int, height: Int,
                             pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> UIImage {
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 255, count: height * bytesPerRow)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let i = y * bytesPerRow + x * 4
                data[i] = r; data[i + 1] = g; data[i + 2] = b
            }
        }
        guard let ctx = CGContext(data: &data, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let cg = ctx.makeImage() else { return UIImage() }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Screen and row styling

extension View {
    /// White backdrop for plain lists (catalog, history, search…), whose rows
    /// are zebra-striped (`zebraRow`) as the back of the player's are, light
    /// in either theme. Apply to the screen's root list.
    /// Section bands sit flush against each other and the bar, as in iOS 6.
    ///
    /// Below the last row the hairlines carry on to the foot of the screen,
    /// `emptyRowHeight` apart, as UITableView drew its empty rows; `nil` leaves
    /// the space blank, as a table with a footer view did.
    func plainBackground(emptyRowHeight: CGFloat? = 44) -> some View {
        flushSections()
            .scrollContentBackground(.hidden)
            .modifier(EmptyRowLines(pitch: emptyRowHeight))
            .background(Palette.cell.ignoresSafeArea())
            .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private func flushSections() -> some View {
        listSectionSpacing(0)
            .contentMargins(.top, 0, for: .scrollContent)
    }

    /// Pinstripe backdrop for grouped lists (settings, pickers, the book page).
    func pinstripeBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(PinstripeBackground())
    }

    /// A plain-list row the iOS 6 way: the full width of the screen with 10pt
    /// margins of its own, and the light-grey hairline running edge to edge.
    /// (Rows are cell-coloured on their own; leaving the background alone lets a
    /// selected row turn blue.) Apply to the rows, their `ForEach` or `Section`.
    func plainRow() -> some View {
        padding(.horizontal, RowMetrics.margin)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            .listRowInsets(EdgeInsets())
            .listRowSeparatorTint(Palette.separator)
    }

    /// Text pressed into the pinstripe: dark slate with a white highlight below
    /// (light grey with a dark edge below, on the dark theme's linen). Surfaces
    /// that stay light in both themes set `.colorScheme(.light)` on themselves.
    func embossed(_ color: Color = Palette.embossed) -> some View {
        foregroundStyle(color)
            .shadow(color: Palette.embossShadow, radius: 0, x: 0, y: 1)
    }

    /// Text engraved into dark chrome: white with a black edge above.
    func engraved(_ color: Color = .white) -> some View {
        foregroundStyle(color)
            .shadow(color: .black.opacity(0.6), radius: 0, x: 0, y: -1)
    }

    /// A cover lifted off the page by a soft shadow below it, cast by a shape
    /// behind the cover rather than by its pixels, so a scrolling list doesn't
    /// render each cover's shadow offscreen. Covers are square-cornered.
    func coverShadow() -> some View {
        background {
            Rectangle().fill(.black)
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
        }
    }
}

/// UITableView's separators for the rows it didn't have: hairlines from the
/// bottom of the content to the bottom of the screen, scrolling with it.
private struct EmptyRowLines: ViewModifier {
    let pitch: CGFloat?
    /// Where the content ends, in the list's own coordinates; nil while empty.
    @State private var contentBottom: CGFloat?
    @Environment(\.displayScale) private var scale

    func body(content: Content) -> some View {
        if let pitch {
            content
                .onScrollGeometryChange(for: CGFloat?.self) { geo in
                    // Only while the end of the content is on screen, so scrolling
                    // a long list doesn't redraw the lines every frame.
                    let bottom = geo.contentSize.height - geo.contentOffset.y
                    return geo.contentSize.height > 1 && bottom < geo.containerSize.height ? bottom : nil
                } action: { _, bottom in
                    contentBottom = bottom
                }
                .background {
                    Canvas { context, size in
                        guard let contentBottom else { return }
                        let line = 1 / scale
                        var y = contentBottom + pitch
                        while y < size.height {
                            context.fill(Path(CGRect(x: 0, y: y - line, width: size.width, height: line)),
                                         with: .color(Palette.separator))
                            y += pitch
                        }
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}
