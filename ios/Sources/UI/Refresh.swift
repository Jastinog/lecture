import SwiftUI

// Pull a list down and the classic spinner fades in above it; pulled far
// enough, it holds the list open while it reloads.

extension View {
    /// Pull-to-refresh in the iOS 6 style.
    func classicRefreshable(_ action: @escaping @Sendable () async -> Void) -> some View {
        modifier(ClassicRefresh(action: action))
    }
}

private struct ClassicRefresh: ViewModifier {
    let action: @Sendable () async -> Void

    /// Where the content's top is: the inset above it (bars, search strip,
    /// our band) and how far down it's scrolled, both positive downwards.
    private struct Place: Equatable {
        var inset: CGFloat = 0
        var top: CGFloat = 0
    }

    @State private var place = Place()
    @State private var refreshing = false
    /// Re-armed once the list is back at rest, so one pull refreshes once.
    @State private var armed = true

    /// Pull distance at which the list reloads.
    private let trigger: CGFloat = 95
    /// Height held open above the list while it reloads.
    private let band: CGFloat = 44

    /// The inset without our band: where the spinner's gap begins.
    private var base: CGFloat { place.inset - (refreshing ? band : 0) }
    /// How far below that the content's top is: the pull, plus the band while
    /// it's held open.
    private var gap: CGFloat { max(0, place.top - base) }

    func body(content: Content) -> some View {
        content
            // As safe area, not a content margin: the lists set their own
            // top margin (`plainBackground`), which would win.
            .safeAreaPadding(.top, refreshing ? band : 0)
            .onScrollGeometryChange(for: Place.self) { geometry in
                Place(inset: geometry.contentInsets.top, top: -geometry.contentOffset.y)
            } action: { _, place in
                self.place = place
                let pull = place.top - place.inset
                if pull < 2 { armed = true }
                if armed, !refreshing, pull >= trigger { start() }
            }
            // Behind the rows, as it were: shown only in the gap above them, so
            // the list slides over it.
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    if refreshing || gap > 2 {
                        ClassicSpinner()
                            .frame(height: band)
                            .opacity(refreshing ? 1 : min(gap / trigger, 1))
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: gap, alignment: .top)
                .clipped()
                .padding(.top, base)
                // Measured, as the inset is, from the list's top under the bars.
                .ignoresSafeArea(.container, edges: .top)
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
