import SwiftUI

// iOS 6's UIRefreshControl: pull a list down and a grey drop with a refresh arrow
// appears above it; pull further and the drop stretches into a teardrop whose
// tail thins as it follows your finger, until it snaps and becomes a spinner
// that holds the list open while it reloads.

extension View {
    /// Pull-to-refresh in the iOS 6 style.
    func classicRefreshable(_ action: @escaping @Sendable () async -> Void) -> some View {
        modifier(ClassicRefresh(action: action))
    }
}

private struct ClassicRefresh: ViewModifier {
    let action: @Sendable () async -> Void

    /// How far the list is pulled past its top.
    @State private var pull: CGFloat = 0
    /// The top inset of the content (bars, search strip) without our band.
    @State private var inset: CGFloat = 0
    @State private var refreshing = false
    /// Re-armed once the list is back at rest, so one pull refreshes once.
    @State private var armed = true

    /// Pull distance at which the drop snaps.
    private let trigger: CGFloat = 95
    /// Height held open above the list while it reloads.
    private let band: CGFloat = 44

    func body(content: Content) -> some View {
        content
            .contentMargins(.top, refreshing ? band : 0, for: .scrollContent)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                -(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, overscroll in
                pull = max(0, overscroll)
                if pull < 2 { armed = true }
                if armed, !refreshing, pull >= trigger { start() }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, top in
                inset = top - (refreshing ? band : 0)
            }
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    if refreshing {
                        ClassicSpinner()
                            .frame(height: band)
                            .transition(.opacity)
                    } else if pull > 2 {
                        RefreshDrop(pull: pull, trigger: trigger)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: (refreshing ? band : 0) + pull, alignment: .top)
                .clipped()
                .padding(.top, inset)
                .allowsHitTesting(false)
            }
    }

    private func start() {
        armed = false
        withAnimation(.easeOut(duration: 0.2)) { refreshing = true }
        Task {
            await action()
            withAnimation(.easeInOut(duration: 0.3)) { refreshing = false }
        }
    }
}

/// The grey drop: a head circle carrying the arrow and a tail circle that
/// follows the pull, joined by a waist that thins as it stretches.
private struct RefreshDrop: View {
    let pull: CGFloat
    let trigger: CGFloat

    var body: some View {
        let progress = min(pull / trigger, 1)
        let headRadius = 15 - 3 * progress
        let tailRadius = 15 - 10 * progress
        let top: CGFloat = 7
        let headY = top + headRadius
        // The tail rides the bottom of the revealed gap once the head fits.
        let tailY = max(headY, min(pull - tailRadius - 4, headY + trigger))
        ZStack(alignment: .top) {
            DropShape(headRadius: headRadius, tailRadius: tailRadius, headY: headY, tailY: tailY)
                .fill(LinearGradient(colors: [Palette.rgb(0xA8ACB2), Palette.rgb(0x8C9097)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    DropShape(headRadius: headRadius, tailRadius: tailRadius, headY: headY, tailY: tailY)
                        .stroke(.black.opacity(0.3), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            Image.classic("RefreshBlobEffect")
                .resizable()
                .frame(width: headRadius * 2, height: headRadius * 2)
                .padding(.top, top)
            Image.classic("RefreshArrow")
                .resizable()
                .frame(width: headRadius * 1.3, height: headRadius * 1.3)
                .padding(.top, headY - headRadius * 0.65)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct DropShape: Shape {
    var headRadius: CGFloat
    var tailRadius: CGFloat
    var headY: CGFloat
    var tailY: CGFloat

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let head = Path(ellipseIn: CGRect(x: cx - headRadius, y: headY - headRadius,
                                          width: headRadius * 2, height: headRadius * 2))
        let tail = Path(ellipseIn: CGRect(x: cx - tailRadius, y: tailY - tailRadius,
                                          width: tailRadius * 2, height: tailRadius * 2))
        // The waist: each side curves in from the head's equator to the tail's.
        let midY = (headY + tailY) / 2
        let pinch = tailRadius * 0.6
        var waist = Path()
        waist.move(to: CGPoint(x: cx - headRadius, y: headY))
        waist.addQuadCurve(to: CGPoint(x: cx - tailRadius, y: tailY), control: CGPoint(x: cx - pinch, y: midY))
        waist.addLine(to: CGPoint(x: cx + tailRadius, y: tailY))
        waist.addQuadCurve(to: CGPoint(x: cx + headRadius, y: headY), control: CGPoint(x: cx + pinch, y: midY))
        waist.closeSubpath()
        // One outline, so the stroke doesn't trace the circles inside the drop.
        return head.union(waist).union(tail)
    }
}
