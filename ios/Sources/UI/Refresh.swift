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

    /// How far the list is pulled past its top.
    @State private var pull: CGFloat = 0
    /// The top inset of the content (bars, search strip) without our band.
    @State private var inset: CGFloat = 0
    @State private var refreshing = false
    /// Re-armed once the list is back at rest, so one pull refreshes once.
    @State private var armed = true

    /// Pull distance at which the list reloads.
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
                    if refreshing || pull > 2 {
                        ClassicSpinner()
                            .frame(height: band)
                            .opacity(refreshing ? 1 : min(pull / trigger, 1))
                            .transition(.opacity)
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
