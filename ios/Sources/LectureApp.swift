import SwiftUI
import UIKit

@main
struct LectureApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Roomier URL cache so covers seen before still show offline.
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 300 << 20)
        ClassicAppearance.apply()
        ClassicTransitions.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Palette.accent)
                .font(.app(.body))
                // Light, dark or the phone's, set on the window so UIKit's
                // bars follow along with the views.
                .onAppear { ThemeStore.shared.apply() }
        }
    }
}

/// Bridges UIKit's background-URLSession callback into the download manager so
/// finished offline downloads are committed when iOS relaunches the app.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // Delegate methods run on the main thread.
        MainActor.assumeIsolated {
            DownloadManager.shared.handleBackgroundEvents(completionHandler: completionHandler)
        }
    }
}

/// The four top-level sections. Single source of truth for each section's
/// label and root stack.
enum SidebarTab: String, CaseIterable, Identifiable {
    case home, lecturers, history, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:      return "Home"
        case .lecturers: return "Lecturers"
        case .history:   return "History"
        case .settings:  return "Settings"
        }
    }

    /// The tab's icon: UIKit's own iOS 6 templates where one fits, else drawn.
    var icon: TabIcon {
        switch self {
        case .home:      return .home
        case .lecturers: return .lecturer
        case .history:   return .classic("TabHistory")
        case .settings:  return .gear
        }
    }

    /// The section's persistent navigation router.
    @MainActor var router: NavRouter {
        switch self {
        case .home:      return TabRouter.home
        case .lecturers: return TabRouter.lecturers
        case .history:   return TabRouter.history
        case .settings:  return TabRouter.settings
        }
    }
}

struct RootView: View {
    @StateObject private var player = AudioPlayer.shared
    @ObservedObject private var tabBar = TabBarVisibility.shared
    @State private var selection: SidebarTab = .home

    var body: some View {
        content
            .environmentObject(player)
            .overlay { ActionSheetHost() }
            .overlay { AlertHost() }
            // A lecture that won't play says so wherever the listener is.
            .onChange(of: player.playbackError) { _, error in
                guard let error else { return }
                Alerts.shared.show("Can’t Play", message: error, [
                    AlertButton(title: "OK") { player.playbackError = nil },
                    AlertButton(title: "Try Again", isDefault: true) { player.play() },
                ])
            }
    }

    /// The navigation stack for one section — its persistent router plus its root
    /// view. Each router is a singleton (`TabRouter`),
    /// so an open topic page survives the stack being torn down and remounted.
    @ViewBuilder
    func rootStack(for tab: SidebarTab) -> some View {
        RoutedStack(router: tab.router) {
            switch tab {
            case .home:      CatalogView().libraryDestinations()
            case .lecturers: LecturersView().libraryDestinations()
            case .history:   HistoryView()
            case .settings:  SettingsView()
            }
        }
    }
}

// MARK: - iOS shell (classic tab bar)

extension RootView {
    /// Every section's stack stays mounted (only the selected one is visible), so
    /// switching tabs keeps scroll positions and open pages, like a real tab bar.
    /// There's no mini player: as in iOS 6 Music, a "Now Playing" button in
    /// each bar pushes the player. The keyboard slides over the tab bar, as it
    /// did on iOS 6.
    ///
    /// The bar sits under the stacks rather than in a `safeAreaInset`: the
    /// UIKit-hosted navigation stacks don't pass such an inset on to their
    /// lists, which then scrolled their last rows under the bar.
    var content: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(SidebarTab.allCases) { tab in
                    let visible = selection == tab
                    rootStack(for: tab)
                        .opacity(visible ? 1 : 0)
                        .allowsHitTesting(visible)
                        .accessibilityHidden(!visible)
                }
            }
            if !tabBar.hidden {
                ClassicTabBar(selection: $selection) { $0.router.popToRoot() }
                    .transition(.move(edge: .leading))
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}
