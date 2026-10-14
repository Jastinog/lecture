import SwiftUI

extension Font {
    /// A semantic text style in Helvetica Neue, the iOS 6 system face.
    ///
    /// Sizes follow iOS's semantic scale and still track Dynamic Type
    /// (`relativeTo:`). Use `.font(.app(.subheadline, weight: .semibold))` in place of
    /// `.font(.subheadline.weight(.semibold))`.
    static func app(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        let w = weight ?? (style == .headline ? .bold : .regular)
        return .custom(helveticaName(w), size: pointSize(style), relativeTo: style)
    }

    /// Helvetica Neue at a fixed point size: the bars, buttons and badges, which
    /// keep their size as UIKit's chrome does.
    static func helvetica(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(helveticaName(weight), fixedSize: size)
    }

    /// Helvetica Neue at `size` for the default text size, growing and shrinking
    /// with Dynamic Type as `style` does: content (rows, descriptions, alerts).
    static func helvetica(_ size: CGFloat, weight: Font.Weight = .regular,
                          relativeTo style: Font.TextStyle) -> Font {
        .custom(helveticaName(weight), size: size, relativeTo: style)
    }

    // Table-row type, UITableViewCell's sizes. One-line plain rows use
    // `rowLabel` (UIKit's bold 20); grouped rows `groupedLabel` (bold 17) with
    // `groupedValue` beside it. Media rows stack title, subtitle and detail.
    static let rowLabel = app(.title3, weight: .bold)
    static let groupedLabel = app(.body, weight: .bold)
    static let groupedValue = app(.body)
    static let rowTitle = app(.callout, weight: .bold)
    static let rowSubtitle = helvetica(14, relativeTo: .subheadline)
    static let rowDetail = app(.footnote)
    static let rowCaption = app(.caption)

    /// Helvetica Neue ships four useful cuts; heavier requests map to Bold.
    static func helveticaName(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin: return "HelveticaNeue-Thin"
        case .light: return "HelveticaNeue-Light"
        case .medium: return "HelveticaNeue-Medium"
        case .semibold, .bold, .heavy, .black: return "HelveticaNeue-Bold"
        default: return "HelveticaNeue"
        }
    }

    private static func pointSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle:  return 34
        case .title:       return 28
        case .title2:      return 22
        case .title3:      return 20
        case .headline:    return 17
        case .body:        return 17
        case .callout:     return 16
        case .subheadline: return 15
        case .footnote:    return 13
        case .caption:     return 12
        case .caption2:    return 11
        @unknown default:  return 15
        }
    }
}
