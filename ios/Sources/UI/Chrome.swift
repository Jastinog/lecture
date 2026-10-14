import SwiftUI
import UIKit

// The iOS 6 chrome: glossy bars, bordered bar buttons, the black tab bar, the
// classic search bar, section headers, progress bars and the chrome slider.

// MARK: - Navigation bar (UIKit appearance)

/// Installs the classic navigation bar app-wide: UIKit's own blue-grey bar
/// image, embossed white title and the soft drop shadow under the bar. (The
/// arrow-shaped back button is drawn in SwiftUI, see `classicBackButton()`.)
/// Call once at launch, before the first bar is created.
enum ClassicAppearance {
    static func apply() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Palette.navBarTint)
        appearance.backgroundImage = navBarImage
        appearance.backgroundImageContentMode = .scaleToFill
        appearance.shadowImage = UIImage(named: "Classic/NavBarShadow")
        appearance.titleTextAttributes = titleAttributes(size: 20)

        let bar = UINavigationBar.appearance()
        bar.standardAppearance = appearance
        bar.compactAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactScrollEdgeAppearance = appearance
        bar.prefersLargeTitles = false
        bar.tintColor = .white
    }

    private static func titleAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.5)
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 0
        return [.foregroundColor: UIColor.white,
                .font: UIFont(name: "HelveticaNeue-Bold", size: size) ?? .boldSystemFont(ofSize: size),
                .shadow: shadow]
    }

    /// The 44pt bar plus a one-point top row that stretches to fill the status
    /// bar area, in the bar's bottom colour — iOS 6 tinted the status bar that way.
    /// Blue-grey, or the black bar in the dark theme: one image with both looks,
    /// which the bar picks between by its trait.
    private static var navBarImage: UIImage? {
        let asset = UIImageAsset()
        for style in [UIUserInterfaceStyle.light, .dark] {
            // The screen's scale too, or the bar renders soft on 3x phones.
            let traits = UITraitCollection(traitsFrom: [UITraitCollection(displayScale: UIScreen.main.scale),
                                                        UITraitCollection(userInterfaceStyle: style)])
            guard let bar = UIImage(named: "Classic/NavBar", in: nil, compatibleWith: traits) else { return nil }
            let size = CGSize(width: bar.size.width, height: bar.size.height + 1)
            let format = UIGraphicsImageRendererFormat(for: traits)
            let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                UIColor(Palette.navBarTint).resolvedColor(with: traits).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 1))
                bar.draw(at: CGPoint(x: 0, y: 1))
            }
            let resizable = image.resizableImage(
                withCapInsets: UIEdgeInsets(top: 0, left: 0, bottom: bar.size.height, right: 0), resizingMode: .stretch)
            asset.register(resizable, with: traits)
        }
        return asset.image(with: UITraitCollection(userInterfaceStyle: .light))
    }
}

// MARK: - Back button

extension View {
    /// Replaces the system back chevron with the iOS 6 arrow-shaped bordered
    /// button named after the previous screen. Apply to every pushed screen.
    func classicBackButton() -> some View {
        modifier(ClassicBackButton())
    }
}

private struct ClassicBackButton: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @State private var title = String(localized: "Back")

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ClassicToolbarItem(.leading) {
                    BackBarButton(title: title) { dismiss() }
                }
            }
            .background(PreviousTitleReader { title = $0.isEmpty ? String(localized: "Back") : $0 })
    }
}

/// The arrow-shaped back button, titled after the screen it returns to. Blue in
/// navigation bars, black in the player's bar.
struct BackBarButton: View {
    let title: String
    var black = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: 110)
        }
        .buttonStyle(ClassicBackButtonStyle(black: black))
        .accessibilityLabel("Back to \(title)")
    }
}

/// UIKit's arrow-pointed back button bezel: the arrow is a 14pt cap on the left,
/// the rounded end a 6pt cap on the right.
private struct ClassicBackButtonStyle: ButtonStyle {
    var black = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.helvetica(12, weight: .bold))
            .engraved()
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 15)
            .padding(.trailing, 8)
            .frame(minWidth: 50)
            .frame(height: 30)
            .background {
                Image.classic((black ? "BlackBack" : "NavBack") + (configuration.isPressed ? "Pressed" : ""),
                              leading: 14, trailing: 6)
            }
            .contentShape(Rectangle())
    }
}

/// Reads the title of the screen beneath this one in the navigation stack, for
/// the back button's label.
struct PreviousTitleReader: UIViewControllerRepresentable {
    let onTitle: (String) -> Void

    func makeUIViewController(context: Context) -> Probe { Probe(onTitle: onTitle) }
    func updateUIViewController(_ probe: Probe, context: Context) {}

    final class Probe: UIViewController {
        let onTitle: (String) -> Void
        init(onTitle: @escaping (String) -> Void) {
            self.onTitle = onTitle
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard let nav = navigationController else { return }
            // The stack entry hosting this probe is one of its ancestors.
            var ancestor: UIViewController? = self
            while let vc = ancestor, !nav.viewControllers.contains(vc) { ancestor = vc.parent }
            guard let screen = ancestor, let i = nav.viewControllers.firstIndex(of: screen), i > 0
            else { return }
            onTitle(nav.viewControllers[i - 1].navigationItem.title ?? "")
        }
    }
}

// MARK: - Title

/// A bar title as UINavigationBar drew it: bold 20, engraved, shrinking to
/// 14pt before it gives up and truncates.
struct ClassicTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    /// Room kept clear on each side for the bar buttons ("Back", "Now
    /// Playing"); the title stays centered between them.
    static let sideClearance: CGFloat = 100

    var body: some View {
        Text(title)
            .font(.helvetica(20, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 0, x: 0, y: -1)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .truncationMode(.tail)
            // The principal item isn't held between the bar buttons, so a long
            // title would run over them; past the room it shrinks, then cuts
            // with "…", as UINavigationBar did.
            .frame(maxWidth: max(Self.barWidth - 2 * Self.sideClearance, 0))
            .accessibilityAddTraits(.isHeader)
    }

    /// The navigation bar spans the window's screen.
    @MainActor private static var barWidth: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 390
    }
}

extension View {
    /// `navigationTitle` for titles that may run long (books, people, genres):
    /// the bar shows a `ClassicTitle`, which shrinks to fit.
    func classicNavigationTitle(_ title: String) -> some View {
        navigationTitle(title)
            .toolbar { ToolbarItem(placement: .principal) { ClassicTitle(title) } }
    }
}

// MARK: - Bar edges

enum BarMetrics {
    /// iOS 6 kept bar buttons 5pt from the screen edge. The hand-drawn bars
    /// (player, shelf, search) pad by this; system bars get `ClassicToolbarItem`.
    static let edgeInset: CGFloat = 5
}

/// A navigation-bar item on iOS 6's grid: placed on `edge` and moved out from
/// the modern bar's 16pt margin to `BarMetrics.edgeInset`. Use it for every bar item.
struct ClassicToolbarItem<Content: View>: ToolbarContent {
    let edge: HorizontalEdge
    @ViewBuilder var content: Content

    init(_ edge: HorizontalEdge, @ViewBuilder content: () -> Content) {
        self.edge = edge
        self.content = content()
    }

    var body: some ToolbarContent {
        let shift = 16 - BarMetrics.edgeInset
        ToolbarItem(placement: edge == .leading ? .topBarLeading : .topBarTrailing) {
            content.offset(x: edge == .leading ? -shift : shift)
        }
    }
}

// MARK: - Buttons

/// Which bar a bordered button sits on; each bar had its own bezel artwork.
enum BarButtonSkin {
    /// Blue-grey (navigation bars).
    case blue
    /// Bright blue "Done".
    case done
    /// Black (the player).
    case black
    /// Newsstand's translucent bezel over wood (the shelf).
    case wood

    fileprivate func image(pressed: Bool) -> String {
        switch self {
        case .blue: pressed ? "NavButtonPressed" : "NavButton"
        case .done: pressed ? "NavDonePressed" : "NavDone"
        case .black: pressed ? "BlackButtonPressed" : "BlackButton"
        case .wood: pressed ? "ShelfButtonPressed" : "ShelfButton"
        }
    }

    /// The bezel stretched to its frame: 5pt rounded caps either side.
    func bezel(pressed: Bool = false) -> Image {
        .classic(image(pressed: pressed), leading: 5, trailing: 5)
    }
}

/// A bordered bar button: the small glossy bezel iOS 6 put around every
/// navigation-bar item.
struct ClassicBarButtonStyle: ButtonStyle {
    var skin = BarButtonSkin.blue
    /// Off for full-colour artwork that carries its own emboss.
    var engraved = true

    func makeBody(configuration: Configuration) -> some View {
        BarBezel(skin: skin, pressed: configuration.isPressed, engraved: engraved) {
            configuration.label
        }
    }
}

/// The bezel behind a bar button; also used by controls that aren't `Button`s.
struct BarBezel<Label: View>: View {
    var skin = BarButtonSkin.blue
    var pressed = false
    var engraved = true
    @ViewBuilder var label: Label
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label
            .font(.helvetica(12, weight: .bold))
            .imageScale(.large)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(engraved ? 0.6 : 0), radius: 0, x: 0, y: -1)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(minWidth: 34)
            .frame(height: 30)
            .background { skin.bezel(pressed: pressed) }
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == ClassicBarButtonStyle {
    /// Blue-grey bordered bar button (navigation bars).
    static var classicBar: ClassicBarButtonStyle { ClassicBarButtonStyle() }
    /// Black bordered button (the player's bars).
    static var classicBlackBar: ClassicBarButtonStyle { ClassicBarButtonStyle(skin: .black) }
    /// Newsstand's bezel (the bookshelf header).
    static var classicWoodBar: ClassicBarButtonStyle { ClassicBarButtonStyle(skin: .wood) }
}

/// Large rounded glossy buttons: the blue call to action and the white secondary.
struct ClassicButtonStyle: ButtonStyle {
    enum Kind { case blue, white }
    var kind: Kind = .blue

    func makeBody(configuration: Configuration) -> some View {
        ClassicButtonBody(kind: kind, pressed: configuration.isPressed) { configuration.label }
    }
}

/// The big buttons' colours that differ by theme.
private enum ButtonInk {
    /// The light the background catches under a button; faint on dark.
    static let ledge = Palette.shade(UIColor(white: 1, alpha: 0.6), dark: UIColor(white: 1, alpha: 0.1))
    static let whiteLabel = Palette.rgb(0x324F85, dark: 0xDCE3EE)
    static let whiteTop = Palette.rgb(0xFFFFFF, dark: 0x4C4C4C)
    static let whiteBottom = Palette.rgb(0xE4E4E4, dark: 0x2C2C2C)
    static let whiteBorder = Palette.rgb(0x9AA1A9, dark: 0x0E0E0E)
}

private struct ClassicButtonBody<Label: View>: View {
    let kind: ClassicButtonStyle.Kind
    let pressed: Bool
    @ViewBuilder var label: Label
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Group {
            switch kind {
            case .blue:
                label.engraved()
            case .white:
                label.foregroundStyle(ButtonInk.whiteLabel)
                    .shadow(color: Palette.embossShadow, radius: 0, x: 0, y: 1)
            }
        }
        .font(.helvetica(16, weight: .bold))
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .background {
            Group {
                switch kind {
                case .blue: shape.fill(Palette.blueButton.gradient)
                case .white: shape.fill(LinearGradient(colors: [ButtonInk.whiteTop, ButtonInk.whiteBottom],
                                                       startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay { if pressed { shape.fill(.black.opacity(kind == .blue ? 0.22 : 0.1)) } }
            .overlay {
                shape.strokeBorder(kind == .blue ? Palette.rgb(0x1349A0) : ButtonInk.whiteBorder,
                                   lineWidth: 1)
            }
            .shadow(color: ButtonInk.ledge, radius: 0, x: 0, y: 1)
        }
        .opacity(isEnabled ? 1 : 0.6)
        .contentShape(shape)
    }
}

extension ButtonStyle where Self == ClassicButtonStyle {
    static var classicBlue: ClassicButtonStyle { ClassicButtonStyle(kind: .blue) }
    static var classicWhite: ClassicButtonStyle { ClassicButtonStyle(kind: .white) }
}

// MARK: - Section headers and footers

/// The sticky translucent band that heads a section in a plain list.
struct PlainSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.helvetica(16, weight: .bold))
            .modifier(SectionBandInk())
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SectionBandInk.inset)
            .frame(height: 23)
            .background { Image.classic("SectionHeader").resizable() }
            .listRowInsets(EdgeInsets())
            .textCase(nil)
    }
}

/// White text with the dark shadow under it, as section bands printed it.
private struct SectionBandInk: ViewModifier {
    /// Text to the band's ends.
    static let inset: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: 1)
    }
}

/// A word at the right end of a section band ("Clear", "Filter"). Overlay it
/// on a `PlainSectionHeader`.
struct SectionHeaderButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.helvetica(13, weight: .bold))
            .buttonStyle(.plain)
            .modifier(SectionBandInk())
            .padding(.trailing, SectionBandInk.inset)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}

/// A grouped-table section title, embossed into the pinstripe.
struct GroupHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.app(.body, weight: .bold))
            .embossed()
            .textCase(nil)
    }
}

/// A grouped-table footnote, centred and embossed like iOS 6.
struct GroupFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.app(.subheadline))
            .embossed()
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

/// A settings row: bold title on the left, the value in classic blue-grey on the
/// right.
struct ValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).font(.groupedLabel).rowForeground(Palette.text)
            Spacer(minLength: 8)
            Text(value).font(.groupedValue).rowForeground(Palette.accent).lineLimit(1)
        }
    }
}

// MARK: - Tab bar

/// Whether the tab bar is out of the way. Now Playing hides it, as iOS 6 Music's
/// did (`hidesBottomBarWhenPushed`): it slides off with the screen it was on.
@MainActor
final class TabBarVisibility: ObservableObject {
    static let shared = TabBarVisibility()
    @Published var hidden = false

    func set(hidden: Bool) {
        guard hidden != self.hidden else { return }
        withAnimation(.easeInOut(duration: 0.35)) { self.hidden = hidden }
    }
}

/// The silver tab bar of iOS 6 Music on the iPod touch: each item a button
/// cell of its own between engraved dividers, the selected one pressed in
/// (darker at the top), grey embossed glyphs and labels — no blue. Tapping
/// the selected tab again pops it to its root.
struct ClassicTabBar: View {
    @Binding var selection: SidebarTab
    var reselect: (SidebarTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(SidebarTab.allCases.enumerated()), id: \.element) { i, tab in
                if i > 0 { Self.divider }
                Button {
                    if selection == tab { reselect(tab) } else { selection = tab }
                } label: {
                    TabItem(tab: tab, selected: selection == tab)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .frame(height: 49)
        // The cells, their dividers and the pressed one run on down through
        // the home indicator's strip (which iOS 6 never had), so nothing
        // steps at the bar's foot.
        .background { Self.cell.ignoresSafeArea(edges: .bottom) }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle().fill(Palette.rgb(0x8E8F92)).frame(height: 1)
                Rectangle().fill(.white.opacity(0.8)).frame(height: 1)
            }
        }
    }

    private static let foot = Palette.rgb(0xDCDDDF)

    /// An unpressed cell: silver, lighter at the top.
    static var cell: some View {
        LinearGradient(colors: [Palette.rgb(0xF6F6F7), Palette.rgb(0xE4E5E7), foot],
                       startPoint: .top, endPoint: .bottom)
    }

    /// The pressed-in cell behind the selected item: darker at the top, with
    /// a soft shade falling in from either side instead of hard edges. The
    /// gradient is laid over the bar's height; the strip below keeps its foot.
    static var pressed: some View {
        VStack(spacing: 0) {
            LinearGradient(stops: [.init(color: Palette.rgb(0xA9A9AA), location: 0),
                                   .init(color: Palette.rgb(0xC6C6C7), location: 0.35),
                                   .init(color: Palette.rgb(0xDADADB), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 49)
            Palette.rgb(0xDADADB)
        }
        .overlay {
            HStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 5)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.14)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 5)
            }
        }
    }

    /// An engraved line between cells: a dark hairline with a white one beside it.
    private static var divider: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Palette.rgb(0xA9AAAC))
            Rectangle().fill(.white.opacity(0.9))
        }
        .frame(width: 2)
        .ignoresSafeArea(edges: .bottom)
    }

    /// Glyphs and labels: grey pressed into the silver, a shade darker selected.
    static let label = Palette.rgb(0x5B5C5E)
    static let unlit = LinearGradient(colors: [Palette.rgb(0x9B9C9E), Palette.rgb(0x6C6D70)],
                                      startPoint: .top, endPoint: .bottom)
    static let lit = LinearGradient(colors: [Palette.rgb(0x6E6F72), Palette.rgb(0x48494C)],
                                    startPoint: .top, endPoint: .bottom)

    private struct TabItem: View {
        let tab: SidebarTab
        let selected: Bool

        var body: some View {
            VStack(spacing: 1) {
                Rectangle()
                    .fill(selected ? ClassicTabBar.lit : ClassicTabBar.unlit)
                    .frame(width: 34, height: 30)
                    .mask { icon.frame(width: 34, height: 30) }
                    .shadow(color: .white, radius: 0, y: 1)
                Text(tab.title)
                    .font(.helvetica(10, weight: .bold))
                    .foregroundStyle(ClassicTabBar.label)
                    .shadow(color: .white.opacity(0.9), radius: 0, y: 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { if selected { ClassicTabBar.pressed.ignoresSafeArea(edges: .bottom) } }
            .contentShape(Rectangle())
        }

        @ViewBuilder private var icon: some View {
            switch tab.icon {
            case .classic(let name):
                Image.classic(name).renderingMode(.template)
            case .gear:
                TabGear().fill(style: FillStyle(eoFill: true)).frame(width: 25, height: 25)
            case .home:
                TabHouse().fill(style: FillStyle(eoFill: true)).frame(width: 28, height: 26)
            case .lecturer:
                TabLecturer().fill().frame(width: 32, height: 28)
            }
        }
    }
}

/// What a tab bar item shows: a UIKit template image, or a drawn glyph where
/// iOS 6 had no system item to borrow.
enum TabIcon {
    case classic(String)
    case gear
    case home
    case lecturer
}

/// A house for the Home tab: a pitched roof with its chimney over the walls,
/// the door cut out.
struct TabHouse: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
        var p = Path()
        // Roof, eaves overhanging the walls.
        p.move(to: pt(0.5, 0.02))
        p.addLine(to: pt(1.0, 0.48))
        p.addLine(to: pt(0.9, 0.48))
        p.addLine(to: pt(0.9, 1.0))
        p.addLine(to: pt(0.1, 1.0))
        p.addLine(to: pt(0.1, 0.48))
        p.addLine(to: pt(0.0, 0.48))
        p.closeSubpath()
        // Chimney, standing on the roof's slope (not overlapping it, which
        // the even-odd fill would cut out).
        p.move(to: pt(0.7, 0.08))
        p.addLine(to: pt(0.83, 0.08))
        p.addLine(to: pt(0.83, 0.325))
        p.addLine(to: pt(0.7, 0.205))
        p.closeSubpath()
        // Door.
        p.addRoundedRect(in: CGRect(origin: pt(0.4, 0.62), size: CGSize(width: r.width * 0.2, height: r.height * 0.38)),
                         cornerSize: CGSize(width: 1.5, height: 1.5))
        return p
    }
}

/// A lecturer for the Lecturers tab, after Music's Artists glyph: a figure in
/// profile, speaking into a microphone on its stand.
struct TabLecturer: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
        let w = r.width, h = r.height
        var p = Path()
        // Head, a little forward of the shoulders, on a neck.
        p.addEllipse(in: CGRect(origin: pt(0.5, 0.06), size: CGSize(width: w * 0.3, height: h * 0.36)))
        p.addRect(CGRect(origin: pt(0.6, 0.36), size: CGSize(width: w * 0.14, height: h * 0.12)))
        // Shoulders and chest.
        p.move(to: pt(0.38, 1.0))
        p.addCurve(to: pt(0.64, 0.44), control1: pt(0.38, 0.68), control2: pt(0.48, 0.44))
        p.addCurve(to: pt(1.0, 1.0), control1: pt(0.88, 0.44), control2: pt(1.0, 0.66))
        p.closeSubpath()
        // Microphone at the mouth: a rounded head tilted up toward it…
        let mic = Path(roundedRect: CGRect(x: -w * 0.1, y: -h * 0.055, width: w * 0.2, height: h * 0.11),
                       cornerRadius: h * 0.055)
        p.addPath(mic.applying(CGAffineTransform(rotationAngle: -.pi / 5)
            .concatenating(CGAffineTransform(translationX: r.minX + w * 0.4, y: r.minY + h * 0.34))))
        // …its arm slanting down to the stand, the stand and its foot.
        var arm = Path()
        arm.move(to: pt(0.34, 0.39))
        arm.addLine(to: pt(0.37, 0.42))
        arm.addLine(to: pt(0.24, 0.56))
        arm.addLine(to: pt(0.21, 0.53))
        arm.closeSubpath()
        p.addPath(arm)
        p.addRect(CGRect(origin: pt(0.2, 0.53), size: CGSize(width: w * 0.05, height: h * 0.42)))
        p.addRoundedRect(in: CGRect(origin: pt(0.08, 0.93), size: CGSize(width: w * 0.29, height: h * 0.07)),
                         cornerSize: CGSize(width: 1, height: 1))
        return p
    }
}

/// A gear for the Settings tab, solid with a round hole, in the weight of
/// UIKit's tab templates (there is no system Settings item to borrow).
struct TabGear: Shape {
    var teeth = 8

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let outer = r, inner = r * 0.74, hole = r * 0.3
        let step = 2 * Double.pi / Double(teeth)
        func point(_ radius: CGFloat, _ angle: Double) -> CGPoint {
            CGPoint(x: c.x + radius * CGFloat(cos(angle)), y: c.y + radius * CGFloat(sin(angle)))
        }
        var p = Path()
        for i in 0..<teeth {
            let a = Double(i) * step - .pi / 2
            if i == 0 { p.move(to: point(inner, a - step * 0.3)) }
            p.addLine(to: point(outer, a - step * 0.2))
            p.addLine(to: point(outer, a + step * 0.2))
            p.addLine(to: point(inner, a + step * 0.3))
            p.addArc(center: c, radius: inner, startAngle: .radians(a + step * 0.3),
                     endAngle: .radians(a + step * 0.7), clockwise: false)
        }
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: c.x - hole, y: c.y - hole, width: hole * 2, height: hole * 2))
        return p
    }
}

// MARK: - Search bar

/// The blue-grey search bar: a white pill field in a gradient strip. While the
/// field is active, "Cancel" slides in beside it (clears and puts it away).
struct ClassicSearchBar<Scope: View>: View {
    @Binding var text: String
    let prompt: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool
    var autofocus = false
    /// When set, the bar stands in for the navigation bar: "Cancel" is always
    /// there, and leaves the screen.
    var onCancel: (() -> Void)? = nil
    /// UISearchBar's scope bar, under the field.
    var scope: Scope

    init(text: Binding<String>, prompt: String, onSubmit: @escaping () -> Void = {},
         autofocus: Bool = false, onCancel: (() -> Void)? = nil, @ViewBuilder scope: () -> Scope) {
        _text = text
        self.prompt = prompt
        self.onSubmit = onSubmit
        self.autofocus = autofocus
        self.onCancel = onCancel
        self.scope = scope()
    }

    var body: some View {
        SearchStrip {
            HStack(spacing: 6) {
                magnifier
                TextField(prompt, text: $text)
                    .font(.helvetica(15))
                    .foregroundStyle(.black)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit(onSubmit)
                    // The pill is white in both themes; keep its prompt grey.
                    .environment(\.colorScheme, .light)
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.rgb(0xB2B2B2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
        } accessory: {
            if onCancel != nil || focused {
                Button("Cancel") {
                    focused = false
                    if let onCancel { onCancel() } else { text = "" }
                }
                .buttonStyle(.classicBar)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        } scope: {
            scope
        }
        .animation(.easeInOut(duration: 0.25), value: focused)
        // Standing in for the navigation bar, it keeps the bar's tint under the
        // status bar (see `ClassicAppearance.navBarImage`) for the white text.
        .background(alignment: .top) {
            if onCancel != nil {
                Palette.navBarTint.ignoresSafeArea(edges: .top).frame(height: 0)
            }
        }
        .onAppear { if autofocus { focused = true } }
    }

    private var magnifier: some View { Image.classic("SearchIcon") }
}

extension ClassicSearchBar where Scope == EmptyView {
    init(text: Binding<String>, prompt: String, onSubmit: @escaping () -> Void = {},
         autofocus: Bool = false, onCancel: (() -> Void)? = nil) {
        self.init(text: text, prompt: prompt, onSubmit: onSubmit, autofocus: autofocus,
                  onCancel: onCancel) { EmptyView() }
    }
}

/// A search bar that isn't a field: tapping it opens the search screen. An
/// optional bar button sits after the field, and an optional scope bar
/// (segmented controls) rides on the same strip beneath it.
struct SearchBarLink<Accessory: View, Scope: View>: View {
    let prompt: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var scope: Scope
    @EnvironmentObject private var router: NavRouter

    init(prompt: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder scope: () -> Scope) {
        self.prompt = prompt
        self.accessory = accessory()
        self.scope = scope()
    }

    var body: some View {
        SearchStrip {
            // A button, not a link: in a list a link would grow a chevron.
            Button { router.push(SearchRoute()) } label: {
                HStack(spacing: 6) {
                    Image.classic("SearchIcon")
                    Text(prompt).font(.helvetica(15)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.rgb(0x9A9A9A))
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")
        } accessory: {
            accessory
        } scope: {
            scope
        }
    }
}

/// Whether a row with these `fields` matches what's typed in a list's search
/// bar: any field containing it, ignoring case (every row, while it's blank).
func searchMatches(_ query: String, _ fields: String?...) -> Bool {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return q.isEmpty || fields.contains { $0?.localizedCaseInsensitiveContains(q) == true }
}

/// A search bar heading a list, as iOS 6 Music and Contacts filtered theirs:
/// the first row, full width, scrolling away with the rows.
struct TableSearchBar: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        ClassicSearchBar(text: $text, prompt: prompt)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// UIKit's search bar strip and its white pill field, shared by both search bars,
/// with room for a bar button after the field.
private struct SearchStrip<Content: View, Accessory: View, Scope: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory
    /// UISearchBar's scope bar: rows under the field on one stretched strip.
    @ViewBuilder var scope: Scope

    init(@ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder scope: () -> Scope = { EmptyView() }) {
        self.content = content()
        self.accessory = accessory()
        self.scope = scope()
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                content
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background {
                        HStack(spacing: 0) {
                            Image.classic("SearchFieldLeft")
                            Image.classic("SearchFieldMiddle").resizable()
                            Image.classic("SearchFieldRight")
                        }
                    }
                accessory
            }
            scope
        }
        .padding(.horizontal, BarMetrics.edgeInset)
        .padding(.vertical, 7)
        .background { Image.classic("SearchBar").resizable() }
    }
}

// MARK: - Progress and sliders

/// UIProgressView: the inset grey track with the glossy blue fill.
struct ClassicProgressBar: View {
    let value: Double
    var height: CGFloat = 9

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Image.classic("ProgressTrack", leading: 5, trailing: 5)
                if fraction > 0 {
                    Image.classic("ProgressFill", leading: 5, trailing: 5)
                        .frame(width: max(11, geo.size.width * fraction))
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(formatPercent(value))
    }
}

/// A slider in UIKit's artwork: the standard UISlider, or the Music player's
/// scrubber (darker track, small chrome knob).
struct ChromeSlider: View {
    enum Style {
        case standard, nowPlaying

        /// Track images (filled, unfilled), their cap width, and the knob.
        fileprivate var parts: (min: String, max: String, cap: CGFloat, knob: String, knobSize: CGFloat) {
            switch self {
            case .standard: ("SliderMin", "SliderMax", 5, "SliderHandle", 23)
            case .nowPlaying: ("ScrubFilled", "ScrubUnfilled", 4, "ScrubKnob", 18)
            }
        }
    }

    let value: Double
    var range: ClosedRange<Double> = 0...1
    var style = Style.standard
    /// Called continuously while dragging with the new value.
    var onChange: (Double) -> Void
    /// `true` when a drag starts, `false` when it ends.
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let parts = style.parts
            let knob = parts.knobSize
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
            let usable = geo.size.width - knob
            let x: CGFloat = knob / 2 + usable * fraction
            let minFill: CGFloat = parts.cap * 2 + 1
            ZStack(alignment: .leading) {
                Image.classic(parts.max, leading: parts.cap, trailing: parts.cap)
                    .frame(height: 9)
                Image.classic(parts.min, leading: parts.cap, trailing: parts.cap)
                    .frame(width: max(minFill, x), height: 9)
                Image.classic(style == .standard && dragging ? "SliderHandleDown" : parts.knob)
                    .frame(width: knob, height: knob)
                    .offset(x: x - knob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { dragging = true; onEditingChanged(true) }
                        let f = min(max((g.location.x - knob / 2) / max(usable, 1), 0), 1)
                        onChange(range.lowerBound + span * f)
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 30)
    }
}

// MARK: - Segmented control

/// A bar-style segmented control built from the bar's own button bezel (the
/// shelf uses Newsstand's). The selected segment wears the pressed bezel.
struct ClassicSegmentedControl<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var skin = BarButtonSkin.wood

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                let on = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.helvetica(11, weight: .bold))
                        .engraved()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background { if on { skin.bezel(pressed: true) } }
                        .overlay(alignment: .leading) {
                            if i > 0 && !on && options[i - 1].value != selection {
                                Rectangle().fill(.black.opacity(0.35)).frame(width: 1).padding(.vertical, 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(height: 30)
        .background { skin.bezel() }
    }
}

/// "Edit" / "Done" in a bordered bar button, toggling the list's edit mode.
struct ClassicEditButton: View {
    @Environment(\.editMode) private var editMode

    var body: some View {
        let editing = editMode?.wrappedValue.isEditing == true
        Button(editing ? "Done" : "Edit") {
            withAnimation { editMode?.wrappedValue = editing ? .inactive : .active }
        }
        .buttonStyle(ClassicBarButtonStyle(skin: editing ? .done : .blue))
    }
}

// MARK: - Now Playing button

/// "Now Playing": iOS 6 Music's arrow-shaped bar button, pointing forward.
/// Shown while a book is loaded; it pushes the player onto the current stack.
struct NowPlayingBarButton: View {
    /// On the shelf's wooden header, which has only Newsstand's rounded bezel.
    var onWood = false
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        if player.topic != nil {
            let link = NavigationLink(value: NowPlayingRoute()) {
                Text("Now\nPlaying")
                    .font(.helvetica(10, weight: .bold))
                    .lineSpacing(-3)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize()
            }
            .accessibilityLabel("Now Playing")
            if onWood {
                link.buttonStyle(.classicWoodBar)
            } else {
                link.buttonStyle(ForwardButtonStyle())
            }
        }
    }
}

/// The trailing bar slot for `NowPlayingBarButton`.
struct NowPlayingToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        ClassicToolbarItem(.trailing) { NowPlayingBarButton() }
    }
}

/// The back button's bezel mirrored: rounded on the left, the arrow on the right.
private struct ForwardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .engraved()
            .padding(.leading, 8)
            .padding(.trailing, 15)
            .frame(height: 30)
            .background {
                Image.classic(configuration.isPressed ? "NavBackPressed" : "NavBack", leading: 14, trailing: 6)
                    .scaleEffect(x: -1)
            }
            .contentShape(Rectangle())
    }
}

// MARK: - Activity indicator

/// iOS 6's UIActivityIndicatorView: its twelve original frames stepped at twelve
/// a second (one turn a second). Grey on white; white on dark chrome.
struct ClassicSpinner: View {
    enum Style: String {
        /// 20pt grey, for white lists and pinstripe.
        case gray = "SpinnerGray"
        /// 20pt white, for dark bars and covers.
        case white = "SpinnerWhite"
        /// 37pt white.
        case whiteLarge = "SpinnerWhiteLarge"
    }

    var style = Style.gray
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Grey would vanish into the dark theme's cells; it spins white there.
        let name = style == .gray && scheme == .dark ? Style.white.rawValue : style.rawValue
        TimelineView(.periodic(from: .now, by: 1.0 / 12)) { context in
            let frame = Int(context.date.timeIntervalSinceReferenceDate * 12) % 12
            Image.classic(name + String(frame))
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

// MARK: - Switch

/// iOS 6's UISwitch, assembled from UIKit's own parts the way UIKit drew it: the
/// blue "on" track and the white "off" track meet under the thumb, and both, with
/// the inset shadow, are clipped to the pill mask; the thumb sits on top. The
/// tracks wear UIKit's I and O glyphs, which it showed outside English, so no
/// language's words have to fit.
struct ClassicToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            ClassicSwitch(isOn: configuration.$isOn)
        }
        // VoiceOver reads the row as one switch named by its label.
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

struct ClassicSwitch: View {
    @Binding var isOn: Bool
    @State private var pressed = false
    @Environment(\.isEnabled) private var isEnabled

    private let width: CGFloat = 79
    private let height: CGFloat = 27
    private let thumb: CGFloat = 29

    var body: some View {
        let side = width - thumb
        let x = isOn ? side : 0
        ZStack(alignment: .leading) {
            ZStack(alignment: .leading) {
                track("SwitchTrackOn", label: Image.classic("SwitchOnLabel"), from: .leading,
                      length: x + thumb / 2)
                // The track is white in both themes.
                track("SwitchTrackOff", label: Image.classic("SwitchOffLabel"),
                      from: .trailing, length: width - x - thumb / 2)
                    .frame(width: width, alignment: .trailing)
                Image.classic("SwitchShadow").resizable()
            }
            .frame(width: width, height: height, alignment: .leading)
            .mask { Image.classic("SwitchMask").resizable() }
            Image.classic(pressed ? "SwitchThumbPressed" : "SwitchThumb")
                .offset(x: x)
        }
        .frame(width: width, height: height)
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { value in
                    pressed = false
                    // A slide picks its side; a tap flips.
                    let slide = value.translation.width
                    let next = abs(slide) > 8 ? slide > 0 : !isOn
                    if next != isOn {
                        withAnimation(.easeInOut(duration: 0.2)) { isOn = next }
                    }
                }
        )
        .accessibilityRepresentation { Toggle("", isOn: $isOn) }
    }

    /// One side's track, `length` long from its edge to the thumb's centre and
    /// tucked a little further under the thumb so its rounded end never shows.
    /// The glyph is centred in the side it shows in when the switch is on it.
    private func track(_ image: String, label: some View, from edge: HorizontalEdge,
                       length: CGFloat) -> some View {
        let cap: CGFloat = 5, tuck = cap + 1
        let inner: Edge.Set = edge == .leading ? .trailing : .leading
        return Image.classic(image, leading: cap, trailing: cap)
            .frame(width: length + tuck)
            .overlay(alignment: edge == .leading ? .trailing : .leading) {
                label
                    .frame(width: width - thumb)
                    .padding(inner, thumb / 2 + tuck)
            }
    }
}

// MARK: - Empty states

/// An empty or failed screen the iOS 6 way: no glyph, just a large grey title and
/// a line of explanation pressed into the background (white lists, or slate on
/// the pinstripe), centred where the rows would be.
struct ClassicEmptyState<Actions: View>: View {
    let title: String
    var message: String?
    var onPinstripe = false
    /// Overrides the ink, for other backgrounds (the shelf's maple).
    var color: Color?
    @ViewBuilder var actions: Actions

    init(_ title: String, message: String? = nil, onPinstripe: Bool = false, color: Color? = nil,
         @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.message = message
        self.onPinstripe = onPinstripe
        self.color = color
        self.actions = actions()
    }

    var body: some View {
        let color = color ?? (onPinstripe ? Palette.embossed : Palette.secondaryText)
        VStack(spacing: 10) {
            Text(title)
                .font(.app(.title3, weight: .bold))
            if let message {
                Text(message)
                    .font(.app(.subheadline))
            }
            actions
                .padding(.top, 6)
        }
        .embossed(color)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension ClassicEmptyState where Actions == EmptyView {
    /// A search or filter that matched nothing.
    static var noResults: Self {
        Self(String(localized: "No Results"), message: String(localized: "Try a different search"))
    }
}

/// A page that couldn't load, with a button to try again.
struct LoadFailedState: View {
    let retry: () async -> Void

    var body: some View {
        ClassicEmptyState(String(localized: "Couldn’t Load"), message: String(localized: "Check your connection")) {
            Button("Try Again") { Task { await retry() } }.buttonStyle(.classicWhite)
        }
    }
}

// MARK: - Table rows

private struct RowHighlightedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the enclosing table row is selected (blue): its text turns white.
    var rowHighlighted: Bool {
        get { self[RowHighlightedKey.self] }
        set { self[RowHighlightedKey.self] = newValue }
    }
}

/// A UITableViewCell's selection in SwiftUI: while the row is pressed or
/// `selected`, its text turns white (see `rowForeground`) and a disclosure arrow,
/// if any, turns white too. The blue itself is the row's background, set by
/// `RowLink` / `RowButton`, which learn about presses through `pressed`.
struct ClassicRowStyle: ButtonStyle {
    var selected = false
    var disclosure = false
    var pressed: Binding<Bool>? = nil

    func makeBody(configuration: Configuration) -> some View {
        let on = selected || configuration.isPressed
        HStack(spacing: 8) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            if disclosure {
                RowDisclosure(on: on)
            }
        }
        .foregroundStyle(on ? Color.white : Palette.text)
        .environment(\.rowHighlighted, on)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onChange(of: configuration.isPressed) { _, isPressed in pressed?.wrappedValue = isPressed }
    }
}

/// The disclosure arrow, white on a selected row. It fades out while the row's
/// swipe button or edit control is out.
private struct RowDisclosure: View {
    let on: Bool
    @Environment(\.rowAccessoryHidden) private var hidden

    var body: some View {
        if !hidden {
            Image.classic(on ? "DisclosureSelected" : "Disclosure")
                .transition(.opacity)
        }
    }
}

/// UIKit's blue selection gradient as a row background, or the plain cell.
private func rowBackground(_ on: Bool) -> some View {
    Group {
        if on { Image.classic("Selection").resizable() } else { Palette.cell }
    }
}

/// A table row that pushes `value`, iOS 6 style: it turns blue under the finger,
/// stays blue while the next screen slides in, and fades back when you return.
struct RowLink<Label: View>: View {
    private let open: (NavRouter) -> Void
    var disclosure = true
    private var longPress: (() -> Void)?
    @ViewBuilder var label: Label

    @EnvironmentObject private var router: NavRouter
    @State private var pressed = false
    /// Set when a long press fires, so letting go doesn't also open the row.
    @State private var longPressed = false
    /// Held after the push; cleared once the stack is back at `depth`.
    @State private var selected = false
    @State private var depth = 0

    init<Value: Hashable>(value: Value, disclosure: Bool = true, @ViewBuilder label: () -> Label) {
        self.open = { $0.push(value) }
        self.disclosure = disclosure
        self.label = label()
    }

    /// A row whose destination is chosen by `open` (which pushes onto the stack).
    init(disclosure: Bool = true, open: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.open = { _ in open() }
        self.disclosure = disclosure
        self.label = label()
    }

    /// A long press does `action` instead of opening the row (iOS 6 had no
    /// context menus; the row offers an action sheet).
    func onLongPress(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.longPress = action
        return copy
    }

    var body: some View {
        Button {
            if longPressed { longPressed = false; return }
            depth = router.path.count
            selected = true
            open(router)
        } label: {
            label
        }
        .buttonStyle(ClassicRowStyle(selected: selected, disclosure: disclosure, pressed: $pressed))
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            longPressed = true
            longPress?()
        }, isEnabled: longPress != nil)
        .onChange(of: pressed) { _, isPressed in if isPressed { longPressed = false } }
        .listRowBackground(rowBackground(selected || pressed))
        .preference(key: RowSelectedKey.self, value: selected || pressed)
        .onChange(of: router.path.count) { _, count in
            if selected && count <= depth {
                withAnimation(.easeOut(duration: 0.3)) { selected = false }
            }
        }
    }
}

/// A table row that acts in place: blue while pressed.
struct RowButton<Label: View>: View {
    var disclosure = false
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var pressed = false

    init(disclosure: Bool = false, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.disclosure = disclosure
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(ClassicRowStyle(disclosure: disclosure, pressed: $pressed))
            .listRowBackground(rowBackground(pressed))
            .preference(key: RowSelectedKey.self, value: pressed)
    }
}

extension View {
    /// Text colour that turns white in a selected row.
    func rowForeground(_ color: Color) -> some View {
        modifier(RowForeground(color: color))
    }
}

private struct RowForeground: ViewModifier {
    let color: Color
    @Environment(\.rowHighlighted) private var highlighted

    func body(content: Content) -> some View {
        content.foregroundStyle(highlighted ? .white : color)
    }
}
