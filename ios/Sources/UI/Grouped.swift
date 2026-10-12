import SwiftUI

// iOS 6's grouped table, drawn here rather than borrowed from `List` (whose
// sections can't carry a border, and whose rows don't know where they sit). On
// the pinstripe, each section is a white panel 10pt in from the screen's sides
// with 8pt corners, a 1px grey border and a white highlight under it, grey
// hairlines between rows, every row at least 44pt. A selected row's blue is
// clipped by the panel, so a top or bottom row lights up with rounded corners,
// as UIKit drew it.

enum GroupedMetrics {
    /// Panel to screen edge.
    static let margin: CGFloat = 10
    static let corner: CGFloat = 8
    /// Row content to panel edge.
    static let rowInset: CGFloat = 10
    static let rowHeight: CGFloat = 44
}

extension Palette {
    /// The grouped panel's border and the hairlines between its rows.
    static let groupedBorder = rgb(0xABABAB, dark: 0x0C0C0C)
    /// The edge a panel's bottom catches below its border.
    static let panelHighlight = shade(UIColor(white: 1, alpha: 0.85), dark: UIColor(white: 1, alpha: 0.14))
}

/// A scrolling grouped screen on the pinstripe. Holds `GroupedSection`s and any
/// free content between them (a hero, a big button), which lines up with the
/// panels' edges.
struct GroupedList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            // Grouped rows' type and controls, set once for the whole screen.
            .font(.groupedLabel)
            .toggleStyle(ClassicToggleStyle())
            .padding(.horizontal, GroupedMetrics.margin)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .background(PinstripeBackground())
    }
}

/// One section of a `GroupedList`: an optional embossed title, the panel of
/// rows, an optional centred footnote. Each child view of `content` is a row.
struct GroupedSection<Content: View>: View {
    var header: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ header: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                // UIKit set the title 19pt in from the screen (9 in from the
                // panel), 13pt below the section above and 9pt over its panel.
                GroupHeader(header)
                    .padding(.horizontal, GroupedMetrics.rowInset - 1)
                    .padding(.vertical, 9)
            }
            panel
            if let footer {
                GroupFooter(footer)
                    .padding(.horizontal, GroupedMetrics.rowInset)
                    .padding(.top, 6)
            }
        }
        .padding(.bottom, 14)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    GroupedCell { row }
                    if row.id != rows.last?.id {
                        Rectangle().fill(Palette.groupedBorder).frame(height: 1)
                    }
                }
            }
        }
        .groupedPanel()
    }
}

extension View {
    /// A grouped section's panel around this content: white (dark grey), 8pt corners, the
    /// grey border, and the white edge its bottom catches in the pinstripe.
    func groupedPanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: GroupedMetrics.corner)
        return background(Palette.panel)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Palette.groupedBorder, lineWidth: 1) }
            .background { shape.fill(Palette.panelHighlight).offset(y: 1) }
    }
}

/// A row of a grouped panel: inset content, the 44pt minimum, and the selection
/// blue behind it when the row reports itself selected.
private struct GroupedCell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, GroupedMetrics.rowInset)
            .frame(maxWidth: .infinity, minHeight: GroupedMetrics.rowHeight, alignment: .leading)
            .backgroundPreferenceValue(RowSelectedKey.self) { on in
                if on { Image.classic("Selection").resizable() }
            }
    }
}

/// Whether the row inside is selected (pressed, or held through a push):
/// `RowLink` and `RowButton` report it, outside a `List` too.
struct RowSelectedKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// A destructive action as a grouped row: bold, centred, black — iOS 6 Settings'
/// "Clear History". It confirms with an action sheet.
struct GroupedActionRow: View {
    let title: String
    var message: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        RowButton(action: {
            ActionSheets.shared.show(message, [.destructive(title, action: action)])
        }) {
            Text(title)
                .font(.groupedLabel)
                .rowForeground(isEnabled ? Palette.text : Palette.secondaryText)
                .frame(maxWidth: .infinity)
        }
    }
}

/// UIKit's big red button (Contacts' "Delete Contact"), on the pinstripe below
/// a section.
struct ClassicDeleteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.helvetica(18, weight: .bold))
            .engraved()
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background {
                Image.classic(configuration.isPressed ? "BigDeleteButtonPressed" : "BigDeleteButton",
                              leading: 6, trailing: 6)
            }
            .contentShape(Rectangle())
    }
}
