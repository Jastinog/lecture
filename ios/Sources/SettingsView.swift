import SwiftUI

struct SettingsView: View {
    @ObservedObject private var player = AudioPlayer.shared
    @ObservedObject private var recents = RecentsStore.shared
    @ObservedObject private var dl = DownloadManager.shared
    @ObservedObject private var theme = ThemeStore.shared
    @State private var language = AppLanguage.chosen

    var body: some View {
        GroupedList {
            languageSection
            appearanceSection
            playbackSection
            downloadsSection
            dataSection
            aboutSection
        }
        .navigationTitle("Settings")
        .toolbar {
            NowPlayingToolbarItem()
        }
        .libraryDestinations()
    }

    private var languageSection: some View {
        GroupedSection {
            PickerRow(title: String(localized: "Language"), options: AppLanguage.allCases, label: \.name,
                      selection: language, pick: pick)
        }
    }

    private func pick(_ language: AppLanguage) {
        guard language != self.language else { return }
        language.choose()
        self.language = language
        // iOS loads an app's language once, at launch.
        if language != .current {
            Alerts.shared.show(language.name, message: language.localized(
                "Close the app and open it again to switch the language."))
        }
    }

    private var appearanceSection: some View {
        GroupedSection(String(localized: "Appearance"),
                       footer: theme.theme == .system ? String(localized: "Light or dark, following the iPhone’s own setting.") : nil) {
            PickerRow(title: String(localized: "Theme"), options: AppTheme.allCases, label: \.title,
                      selection: theme.theme, pick: { theme.theme = $0 })
        }
    }

    private var playbackSection: some View {
        GroupedSection(String(localized: "Playback"),
                       footer: String(localized: "After a pause of more than 30 seconds, the topic rewinds 10–30 seconds so it’s easier to pick up the thread.")) {
            PickerRow(title: String(localized: "Default Speed"), options: AudioPlayer.ratePresets,
                      label: AudioPlayer.rateLabel, selection: player.defaultRate,
                      pick: player.setDefaultRate)
            PickerRow(title: String(localized: "Skip Back"), options: AudioPlayer.skipSteps,
                      label: { String(localized: "\(Int($0)) s") }, selection: player.skipBack,
                      pick: { player.setSkip(back: $0) })
            PickerRow(title: String(localized: "Skip Forward"), options: AudioPlayer.skipSteps,
                      label: { String(localized: "\(Int($0)) s") }, selection: player.skipForward,
                      pick: { player.setSkip(forward: $0) })
            Toggle("Rewind After Pause", isOn: Binding(
                get: { player.smartRewind }, set: { player.setSmartRewind($0) }))
        }
    }

    private var downloadsSection: some View {
        GroupedSection(String(localized: "Downloads"),
                       footer: dl.cellularAllowed ? nil : String(localized: "Lectures download only over Wi-Fi.")) {
            Toggle("Use Cellular Data", isOn: Binding(
                get: { dl.cellularAllowed }, set: { dl.setCellularAllowed($0) }))
        }
    }

    private var dataSection: some View {
        GroupedSection(String(localized: "Data"),
                       footer: dl.library.isEmpty ? nil : String(localized: "\(dl.library.count) topics downloaded, \(formatBytes(dl.totalSize))")) {
            GroupedActionRow(title: String(localized: "Clear History")) { recents.clear() }
                .disabled(recents.items.isEmpty)
            GroupedActionRow(title: String(localized: "Delete All Downloads"),
                             message: String(localized: "All downloaded topics will be removed from this phone.")) {
                for topic in dl.library { dl.deleteTopic(topic.id) }
            }
            .disabled(dl.library.isEmpty)
        }
    }

    private var aboutSection: some View {
        GroupedSection(String(localized: "About")) {
            ValueRow(title: String(localized: "Version"), value: appVersion)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}

/// The languages the app speaks. Picking one sets the app's own language, the
/// same one Settings › Lectures › Language sets, which iOS applies at launch.
enum AppLanguage: String, CaseIterable {
    case en, ru, uk

    /// Its name in itself, so it reads the same whichever language is on.
    var name: String {
        switch self {
        case .en: return "English"
        case .ru: return "Русский"
        case .uk: return "Українська"
        }
    }

    /// The one the app runs in now.
    static var current: AppLanguage {
        Bundle.main.preferredLocalizations.first.flatMap(AppLanguage.init) ?? .en
    }

    /// The one it runs in from the next launch.
    static var chosen: AppLanguage {
        let preferred = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
        return Bundle.preferredLocalizations(from: allCases.map(\.rawValue), forPreferences: preferred)
            .first.flatMap(AppLanguage.init) ?? current
    }

    func choose() {
        UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
    }

    /// `key` in this language, whichever one the app runs in.
    func localized(_ key: String.LocalizationValue) -> String {
        let bundle = Bundle.main.path(forResource: rawValue, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return String(localized: key, bundle: bundle)
    }
}
