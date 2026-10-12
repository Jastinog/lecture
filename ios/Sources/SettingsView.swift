import SwiftUI

struct SettingsView: View {
    @ObservedObject private var player = AudioPlayer.shared
    @ObservedObject private var recents = RecentsStore.shared
    @ObservedObject private var dl = DownloadManager.shared
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        GroupedList {
            appearanceSection
            playbackSection
            dataSection
            aboutSection
        }
        .navigationTitle("Settings")
        .toolbar {
            NowPlayingToolbarItem()
        }
        .libraryDestinations()
    }

    private var appearanceSection: some View {
        GroupedSection("Appearance",
                       footer: theme.theme == .system ? "Light or dark, following the iPhone’s own setting." : nil) {
            PickerRow(title: "Theme", options: AppTheme.allCases, label: \.title,
                      selection: theme.theme, pick: { theme.theme = $0 })
        }
    }

    private var playbackSection: some View {
        GroupedSection("Playback",
                       footer: "After a pause of more than 30 seconds, the topic rewinds 10–30 seconds so it’s easier to pick up the thread.") {
            PickerRow(title: "Default Speed", options: AudioPlayer.ratePresets,
                      label: AudioPlayer.rateLabel, selection: player.defaultRate,
                      pick: player.setDefaultRate)
            PickerRow(title: "Skip Back", options: AudioPlayer.skipSteps,
                      label: { "\(Int($0)) s" }, selection: player.skipBack,
                      pick: { player.setSkip(back: $0) })
            PickerRow(title: "Skip Forward", options: AudioPlayer.skipSteps,
                      label: { "\(Int($0)) s" }, selection: player.skipForward,
                      pick: { player.setSkip(forward: $0) })
            Toggle("Rewind After Pause", isOn: Binding(
                get: { player.smartRewind }, set: { player.setSmartRewind($0) }))
        }
    }

    private var dataSection: some View {
        GroupedSection("Data",
                       footer: dl.library.isEmpty ? nil : "\(formatCount(dl.library.count, "topic", "topics")) downloaded, \(formatBytes(dl.totalSize))") {
            GroupedActionRow(title: "Clear History") { recents.clear() }
                .disabled(recents.items.isEmpty)
            GroupedActionRow(title: "Delete All Downloads",
                             message: "All downloaded topics will be removed from this phone.") {
                for topic in dl.library { dl.deleteTopic(topic.id) }
            }
            .disabled(dl.library.isEmpty)
        }
    }

    private var aboutSection: some View {
        GroupedSection("About") {
            ValueRow(title: "Version", value: appVersion)
            ValueRow(title: "Catalog", value: "Demo Data")
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}
