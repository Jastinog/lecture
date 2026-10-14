import Foundation
import AVFoundation
import MediaPlayer
import CoreMotion
import UIKit

/// The single source of truth for per-topic listening progress: chapter index,
/// position, and overall fraction. The history shelf and the curated shelf derive
/// their progress from here rather than storing their own copy, so the "Continue"
/// percentage and the resume point can never drift apart. Persisted in a
/// versioned, corruption-safe file (migrated from the old UserDefaults blob).
enum ProgressStore {
    private static let legacyKey = "lecture.progress"
    private static let file = "progress.json"
    private static let version = 1
    /// Positions kept: the topics listened to most recently.
    private static let maxEntries = 500
    /// In-memory cache so reads (e.g. in SwiftUI bodies) don't hit disk and
    /// re-decode the whole map on every access.
    @MainActor private static var cache: [String: Entry]?

    // `savedAt`/`lectureID` are optional so older blobs still decode (a
    // defaulted non-optional would not: see `Store`).
    struct Entry: Codable {
        /// The chapter's place in the lectures as they were played, which a
        /// language filter may have narrowed; `lectureID` is what identifies it.
        var index: Int
        var time: Double
        var fraction: Double = 0
        /// When this position was saved (epoch seconds) — drives the smart rewind
        /// when a topic is resumed after a long break.
        var savedAt: Double? = nil
        /// The chapter itself. Nil in positions saved before it was kept.
        var lectureID: Int? = nil

        /// Where the saved chapter is in `lectures`; nil when it isn't among them.
        func index(in lectures: [Lecture]) -> Int? { lectures.index(of: lectureID, saved: index) }
    }

    @MainActor
    static func save(topicID: Int, index: Int, lectureID: Int?, time: Double, fraction: Double) {
        var all = load()
        all[String(topicID)] = Entry(index: index, time: time, fraction: fraction,
                                    savedAt: Date().timeIntervalSince1970, lectureID: lectureID)
        if all.count > maxEntries {
            let oldest = all.sorted { ($0.value.savedAt ?? 0) < ($1.value.savedAt ?? 0) }
                .prefix(all.count - maxEntries)
            for (key, _) in oldest { all[key] = nil }
        }
        cache = all
        Store.save(all, version: version, to: file)
    }

    @MainActor
    static func entry(topicID: Int) -> Entry? { load()[String(topicID)] }

    /// Listened to the end (see `PlaybackMath.finishedFraction`).
    @MainActor
    static func isFinished(topicID: Int) -> Bool {
        entry(topicID: topicID).map { PlaybackMath.isFinished($0.fraction) } ?? false
    }

    /// Forget a topic's position — kept consistent with history removal so a topic
    /// dropped from "Continue listening" doesn't silently resume mid-way.
    @MainActor
    static func remove(topicID: Int) {
        var all = load()
        guard all.removeValue(forKey: String(topicID)) != nil else { return }
        cache = all
        Store.save(all, version: version, to: file)
    }

    /// Forget every position.
    @MainActor
    static func removeAll() {
        cache = [:]
        Store.save([String: Entry](), version: version, to: file)
    }

    @MainActor
    private static func load() -> [String: Entry] {
        if let cache { return cache }
        let decoded = Store.loadOrMigrate([String: Entry].self, legacyKey: legacyKey,
                                          version: version, file: file, default: [:])
        cache = decoded
        return decoded
    }
}

/// A recently-played topic, for the history and the "Continue" card.
struct RecentTopic: Codable, Identifiable, Hashable {
    /// The topic's list card, so the history renders like the catalog.
    var summary: Topic
    var fraction: Double      // 0…1 overall progress
    var updatedAt: Double     // epoch seconds

    var id: Int { summary.id }
    var title: String { summary.title }
}

/// Persisted list of recently-played topics (UserDefaults), newest first.
@MainActor
final class RecentsStore: ObservableObject {
    static let shared = RecentsStore()
    private let legacyKey = "lecture.recents"
    private let file = "recents.json"
    private let version = 1
    private let maxItems = 20

    @Published private(set) var items: [RecentTopic] = []
    private var lastPersist: Double = 0

    private init() { items = load() }

    /// Records playback progress. `summary` (the rich catalog/page card, when the
    /// opener had one) supplies description / genre / duration / views so the
    /// history shelf renders the same full card as the catalog and favorites.
    /// The fraction is read back from `ProgressStore` (the single source of truth)
    /// so the displayed % and the resume point stay in lockstep.
    func record(topic: TopicDetail, summary: Topic? = nil, at time: Double) {
        let fraction = ProgressStore.entry(topicID: topic.id)?.fraction ?? 0
        let entry = RecentTopic(summary: summary ?? Topic(topic),
                                fraction: min(max(fraction, 0), 1), updatedAt: time)
        let topChanged = items.first?.id != topic.id
        // Saves come every ~5s; leave the list (and every view showing it) alone
        // until the progress moves by a visible step.
        if !topChanged, let top = items.first, abs(top.fraction - entry.fraction) < 0.005 {
            var same = entry
            same.fraction = top.fraction
            same.updatedAt = top.updatedAt
            if same == top { return }
        }
        var all = items.filter { $0.id != topic.id }
        all.insert(entry, at: 0)
        items = Array(all.prefix(maxItems))
        // The shelf updates live from `items`; only hit the disk when the topic
        // at the top changes or at most every 30s (this runs every ~5s).
        if topChanged || time - lastPersist > 30 {
            lastPersist = time
            persist()
        }
    }

    func remove(id: Int) {
        items.removeAll { $0.id == id }
        ProgressStore.remove(topicID: id)   // forget the resume point too — stay consistent
        persist()
    }

    /// Clears the history and every listening position, including those of topics
    /// that dropped off it. The curated shelf (`ShelfStore`) is intentionally left
    /// alone — it's a deliberate user list, not a byproduct of playback.
    func clear() {
        ProgressStore.removeAll()
        items = []
        persist()
    }

    private func persist() { Store.save(items, version: version, to: file) }
    private func load() -> [RecentTopic] {
        Store.loadOrMigrate([RecentTopic].self, legacyKey: legacyKey,
                            version: version, file: file, default: [])
    }
}

/// Sleep-timer mode.
enum SleepMode: Equatable, Identifiable {
    case off
    case minutes(Int)
    case endOfChapter
    var id: String {
        switch self {
        case .off: return "off"
        case .minutes(let m): return "m\(m)"
        case .endOfChapter: return "chapter"
        }
    }
    var title: String {
        switch self {
        case .off: return String(localized: "Off")
        case .minutes(let m): return String(localized: "\(m) min")
        case .endOfChapter: return String(localized: "End of Lecture")
        }
    }
    /// Spelled-out form for the sleep-timer screen ("15 Minutes").
    var longTitle: String {
        if case .minutes(let m) = self { return String(localized: "\(m) Minutes") }
        return title
    }
}

/// The high-frequency playback clock: current position, the playing lecture's
/// duration, and the sleep-timer countdown. Split out of `AudioPlayer` so the time
/// observer's twice-a-second `currentTime` update (and the 1s sleep tick) only
/// invalidates the few views that actually show the time — the scrubber, the
/// mini-player progress bar, the sleep label — instead of every view that observes
/// the player. Observing the whole player previously rebuilt the entire TabView and
/// any open topic page twice a second during playback, stuttering any scroll.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var sleepRemaining: TimeInterval?   // seconds left (minutes mode)

    /// Time left in the chapter.
    var remaining: Double { max(duration - currentTime, 0) }
    /// Position within the chapter, 0…1.
    var fraction: Double {
        duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
    }
}

@MainActor
final class AudioPlayer: ObservableObject {
    static let shared = AudioPlayer()

    @Published private(set) var topic: TopicDetail?
    /// The rich catalog/page card for `topic`, when the opener had one. Carries the
    /// description / reader / series / duration that `TopicDetail` lacks, so the
    /// history shelf renders the same full card as the catalog and favorites.
    private var loadedSummary: Topic?
    /// The whole topic's length, when `topic` is it narrowed to one language: the
    /// overall progress is a share of the whole, so finishing one language doesn't
    /// mark the topic finished (and up for "Clean Up").
    private var wholeDuration: Double?
    @Published private(set) var currentIndex = 0
    @Published private(set) var isPlaying = false
    /// True while the player is stalled waiting for data (buffering), driven by
    /// `timeControlStatus`. UI can show a spinner instead of a fake "playing".
    @Published private(set) var isBuffering = false
    /// User-facing playback error (e.g. a broken/404 stream). Set when the current
    /// item reports `.failed`; cleared on the next successful load.
    @Published var playbackError: String?
    /// The speed in effect for the loaded topic: its own remembered speed, or the
    /// default. Change it with `setRate` (this topic) / `setDefaultRate` (Settings).
    @Published private(set) var rate: Float = 1.0
    /// Settings speed, used for topics without a speed of their own.
    var defaultRate: Float { rates.defaultRate }
    /// Default + per-topic speeds (narrators differ in pace). See `RateTopic`.
    @Published private var rates = RateTopic()
    /// Skip-back / skip-forward step in seconds (Settings; also the lock screen).
    @Published private(set) var skipBack: Double = 30
    @Published private(set) var skipForward: Double = 30
    /// Smart rewind: after a pause, step back a little so the listener catches the
    /// thread again (longer pause → bigger step). Settings toggle.
    @Published private(set) var smartRewind = true

    @Published private(set) var sleepMode: SleepMode = .off

    /// High-frequency playback state (position, duration, sleep countdown) lives on
    /// its own observable so the 0.5s time ticks refresh only the time UI, not every
    /// view that observes the player. See `PlaybackClock`.
    let clock = PlaybackClock()

    /// Private forwarding accessors so the player's own logic keeps reading and
    /// writing `currentTime` / `duration` / `sleepRemaining` unchanged, while the
    /// stored value and its change notification live on `clock`. Deliberately
    /// `private`: views must observe `clock` directly (`player.clock.currentTime`),
    /// so they can't read `player.currentTime` and silently miss the live updates.
    private var currentTime: Double {
        get { clock.currentTime } set { clock.currentTime = newValue }
    }
    private var duration: Double {
        get { clock.duration } set { clock.duration = newValue }
    }
    private var sleepRemaining: TimeInterval? {
        get { clock.sleepRemaining } set { clock.sleepRemaining = newValue }
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    /// Audio-session interruption / route-change observers, registered once for
    /// the lifetime of this (singleton) player.
    private var sessionObservers: [NSObjectProtocol] = []
    /// The start position to apply once the current item reaches `.readyToPlay`.
    /// AVPlayer drops seeks issued before the item is ready, so a freshly loaded
    /// chapter stays paused until this seek lands and only then starts playing
    /// (if `isPlaying` — the user's intent — is still set). Non-nil means "the item
    /// is still loading": time ticks are ignored meanwhile so the stale 0:00 of the
    /// new item can't overwrite the resume point or flash in the progress bar.
    private var pendingResumeTime: Double?
    /// True while a user seek is in flight. The periodic observer keeps reporting
    /// the *old* position until the seek completes; ignoring those ticks is what
    /// stops the progress bar from snapping back and the next skip from being
    /// computed off a stale time.
    private var isSeeking = false
    /// The start seek for the current item has been issued (guards a repeated
    /// `.readyToPlay` notification from issuing it twice).
    private var startIssued = false
    /// Bumped on every seek so only the latest one's completion clears `isSeeking`.
    private var seekGeneration = 0
    /// Wall-clock time of the last progress save (throttles disk writes).
    private var lastSave: Date = .distantPast
    private var sleepTimer: Timer?
    /// Absolute time the sleep timer fires, so the remaining count is derived from
    /// the clock (no drift if a tick is late or skipped).
    private var sleepTarget: Date?
    /// When playback was last paused; the length of the break sizes the smart rewind.
    private var pausedAt: Date?
    /// When the player last stopped on its own while playing (a call, another
    /// app), as seen by the status observer before the interruption note arrives.
    private var externalPauseAt: Date?
    /// Playback was running when the current audio interruption began, so its end
    /// may resume it.
    private var resumeAfterInterruption = false
    /// The last chapter played to its end: the next play starts the topic over
    /// instead of replaying its final seconds.
    private var topicEnded = false
    /// The topic the lock-screen info (and so its artwork) belongs to.
    private var nowPlayingTopicID: Int?
    /// When the minutes sleep timer last fired, and its length — a shake shortly
    /// after resumes playback and restarts the same timer.
    private var sleepFired: (at: Date, minutes: Int)?
    /// Accelerometer for shake-to-extend. Runs only while a sleep timer is active
    /// (or just fired) — and keeps working with the screen locked, since background
    /// audio keeps the app running, unlike the UIKit shake gesture.
    private let motion = CMMotionManager()
    private var lastShake = Date.distantPast

    /// Persisted default playback speed (also set from Settings).
    static let rateKey = "lecture.rate"
    private static let topicRatesKey = "lecture.topicRates"
    private static let skipBackKey = "lecture.skipBack"
    private static let skipForwardKey = "lecture.skipForward"
    private static let smartRewindKey = "lecture.smartRewind"
    /// The loaded topic, so it's back in the player (and on the lock screen)
    /// after a relaunch.
    private static let sessionFile = "now-playing.json"
    private static let sessionVersion = 1

    private struct SavedSession: Codable {
        var topic: TopicDetail
        var summary: Topic?
        var wholeDuration: Double?
    }

    /// Skip steps offered in Settings; each has a matching SF Symbol
    /// (`gobackward.N` / `goforward.N`).
    static let skipSteps: [Double] = [10, 15, 30, 45, 60]

    /// Selectable playback speeds and their display label, shared by the full
    /// player and Settings so the two never drift.
    static let ratePresets: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    static func rateLabel(_ r: Float) -> String {
        r == 1.0 ? "1×" : "\(String(format: "%g", r))×"
    }

    private init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: Self.rateKey) as? Double, stored > 0 {
            rates.defaultRate = Float(stored)
            rate = rates.defaultRate
        }
        rates.perTopic = defaults.dictionary(forKey: Self.topicRatesKey) as? [String: Double] ?? [:]
        if let v = defaults.object(forKey: Self.skipBackKey) as? Double, Self.skipSteps.contains(v) { skipBack = v }
        if let v = defaults.object(forKey: Self.skipForwardKey) as? Double, Self.skipSteps.contains(v) { skipForward = v }
        if let v = defaults.object(forKey: Self.smartRewindKey) as? Bool { smartRewind = v }
        configureSession()
        configureRemoteCommands()
        restoreSession()
    }

    /// Brings back the topic loaded when the app last quit, paused where it was
    /// left. Nothing loads until play: the player is built then.
    private func restoreSession() {
        guard let saved = Store.load(SavedSession.self, from: Self.sessionFile),
              !saved.topic.lectures.isEmpty else { return }
        let topic = saved.topic
        let (start, resume) = adopt(topic, summary: saved.summary, wholeDuration: saved.wholeDuration)
        currentIndex = start.index
        currentTime = start.time
        duration = topic.lectures[start.index].duration
        // Left at the very end: play starts the topic over.
        topicEnded = start.index == topic.lectures.count - 1 && duration > 0
            && (resume?.time ?? 0) >= duration - 1
        updateNowPlaying()
        loadArtwork()
    }

    private func saveSession() {
        guard let topic else { return }
        Store.save(SavedSession(topic: topic, summary: loadedSummary, wholeDuration: wholeDuration),
                   version: Self.sessionVersion, to: Self.sessionFile)
    }

    /// Holds exactly these lectures of the topic — not the topic narrowed to
    /// another language, or the whole of it.
    func holds(_ topic: TopicDetail) -> Bool {
        self.topic?.id == topic.id && self.topic?.lectures.map(\.id) == topic.lectures.map(\.id)
    }

    var currentLecture: Lecture? {
        guard let topic, topic.lectures.indices.contains(currentIndex) else { return nil }
        return topic.lectures[currentIndex]
    }

    // MARK: - Loading

    /// Loads `topic` and starts playing. With `index`, starts that chapter (resuming
    /// its saved position if it is the saved chapter); otherwise resumes wherever
    /// the topic was left. One call, one item load — no throwaway resume load
    /// immediately replaced by a chapter switch.
    /// A topic narrowed to one language comes with only those lectures; loading
    /// it over the whole topic (or the reverse) swaps the queue and keeps the
    /// spot, since positions are kept by lecture.
    func load(topic: TopicDetail, summary: Topic? = nil, index: Int? = nil, whole: TopicDetail? = nil) {
        // Same topic, same lectures, already loaded — switch chapter or just resume.
        if holds(topic), player != nil {
            if let summary { loadedSummary = summary }
            if let index, index != currentIndex {
                play(index: index)
            } else if !isPlaying {
                play()
            }
            return
        }
        guard !topic.lectures.isEmpty else { return }
        // Keep the outgoing topic's spot before its state is replaced.
        if self.topic != nil { persistProgress() }
        let start = adopt(topic, summary: summary, wholeDuration: whole.map(\.totalDuration), index: index).start
        saveSession()
        play(index: start.index, at: start.time)
    }

    /// Makes `topic` the loaded one, at its own remembered speed (or the
    /// default), and works out where it starts: the requested chapter, or where
    /// the topic was left (rewinding a little after a break).
    private func adopt(_ topic: TopicDetail, summary: Topic?, wholeDuration: Double?, index: Int? = nil)
        -> (start: (index: Int, time: Double), resume: ProgressStore.Entry?) {
        self.topic = topic
        loadedSummary = summary
        self.wholeDuration = wholeDuration
        rate = rates.rate(for: topic.id)
        let resume = ProgressStore.entry(topicID: topic.id)
        let start = PlaybackMath.startPosition(
            requested: index, savedIndex: resume?.index(in: topic.lectures), savedTime: resume?.time,
            savedAt: resume?.savedAt, now: Date().timeIntervalSince1970,
            smartRewind: smartRewind, chapterCount: topic.lectures.count)
        return (start, resume)
    }

    /// Loads chapter `index` and positions it at `time`. `autoplay: false` keeps
    /// playback paused (e.g. skipping back across a chapter boundary while paused).
    func play(index: Int, at time: Double = 0, autoplay: Bool = true) {
        guard let topic, topic.lectures.indices.contains(index) else { return }
        currentIndex = index
        let lecture = topic.lectures[index]
        playbackError = nil
        topicEnded = false

        // Local file if the chapter is downloaded, otherwise stream. A streamed URL
        // comes from inline page JS — only allow https (ATS blocks http, but not
        // file:// or other schemes); a local file is our own and always allowed.
        let source: URL
        if let local = DownloadManager.shared.localLectureURL(topicID: topic.id, lectureID: lecture.id) {
            source = local
        } else {
            guard lecture.url.scheme == "https" else {
                // Drop the outgoing item: left playing, its ticks would save its
                // position into this chapter.
                cancelSeeks()
                pendingResumeTime = nil
                duration = lecture.duration
                currentTime = max(0, time)
                playbackError = String(localized: "Unsafe audio address")
                stopInPlace(droppingItem: true)
                return
            }
            source = lecture.url
        }
        // Downloaded files get precise timing, so seeking a VBR MP3 lands exactly
        // where asked instead of on a bitrate estimate. Not for streams: there it
        // would make AVFoundation scan the whole file before playing.
        let asset = source.isFileURL
            ? AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            : AVURLAsset(url: source)
        let item = AVPlayerItem(asset: asset)
        cancelSeeks()   // any in-flight seek belongs to the outgoing item
        if let player {
            player.pause()
            player.replaceCurrentItem(with: item)
        } else {
            let player = AVPlayer(playerItem: item)
            player.pause()
            self.player = player
            addTimeObserver()
            observeTimeControlStatus()
        }
        observeEnd(of: item)
        observeStatus(of: item)
        duration = lecture.duration

        // The item stays paused until it is ready and positioned (see
        // `observeStatus`); `isPlaying` carries the intent across the load, and the
        // spinner shows meanwhile.
        // Not clamped to the page's duration: the real file can be longer, and
        // clamping would cut a saved position short.
        let start = max(0, time)
        pendingResumeTime = start
        startIssued = false
        pausedAt = autoplay ? nil : Date()
        currentTime = start
        isPlaying = autoplay
        isBuffering = autoplay
        if autoplay { activateSession() }
        scheduleLoadTimeout()
        updateNowPlaying()
        loadArtwork()
        persistProgress()
    }

    /// Overall progress (0…1) across all chapters.
    private var overallFraction: Double {
        guard let topic else { return 0 }
        let played = PlaybackMath.fraction(index: currentIndex, time: currentTime,
                                           durations: topic.lectures.map(\.duration))
        guard let wholeDuration, wholeDuration > topic.totalDuration else { return played }
        return played * topic.totalDuration / wholeDuration
    }

    /// Persist progress through the single source of truth (`ProgressStore`) and
    /// then derive the history shelf and the curated shelf from it, so all three
    /// reflect the same playback event.
    private func persistProgress() {
        guard let topic else { return }
        lastSave = Date()
        let fraction = overallFraction
        ProgressStore.save(topicID: topic.id, index: currentIndex, lectureID: currentLecture?.id,
                           time: currentTime, fraction: fraction)
        // Push into "Continue listening" (reads the fraction back from ProgressStore).
        RecentsStore.shared.record(topic: topic, summary: loadedSummary,
                                   at: Date().timeIntervalSince1970)
        // Advance the shelf status for topics already on the shelf (Listening / Finished).
        ShelfStore.shared.applyProgress(id: topic.id, fraction: fraction)
    }

    // MARK: - Controls

    func togglePlayPause() { isPlaying ? pause() : play() }

    func play() {
        guard let player else {
            // A topic brought back from the last launch: load it now.
            if topic != nil { topicEnded ? play(index: 0) : play(index: currentIndex, at: currentTime) }
            return
        }
        // A failed item can't be resumed — reload the chapter where it stopped.
        if playbackError != nil || player.currentItem?.status == .failed {
            play(index: currentIndex, at: currentTime)
            return
        }
        guard !isPlaying else { return }
        if topicEnded {
            play(index: 0)
            return
        }
        isPlaying = true
        externalPauseAt = nil
        if let pausedAt {
            let back = PlaybackMath.rewind(afterPause: Date().timeIntervalSince(pausedAt),
                                           enabled: smartRewind)
            if back > 0 { seek(to: max(0, currentTime - back)) }
        }
        pausedAt = nil
        activateSession()
        // Still loading: the ready handler starts playback once positioned.
        if pendingResumeTime != nil {
            isBuffering = true
        } else {
            player.playImmediately(atRate: rate)
        }
        updateNowPlaying()
    }

    func pause() {
        guard isPlaying else { return }
        player?.pause()
        isPlaying = false
        isBuffering = false
        pausedAt = Date()
        updateNowPlaying()
        // Save right away so pausing and leaving the app never loses the spot.
        persistProgress()
    }

    /// Fully stop playback and clear the current topic, so the mini player is
    /// dismissed. Persists the position first so the topic can be resumed later.
    func stop() {
        if let topic {
            ProgressStore.save(topicID: topic.id, index: currentIndex, lectureID: currentLecture?.id,
                               time: currentTime, fraction: overallFraction)
        }
        tearDownPlayer()
        setSleep(.off)
        isPlaying = false
        isBuffering = false
        playbackError = nil
        topic = nil
        currentIndex = 0
        currentTime = 0
        duration = 0
        topicEnded = false
        nowPlayingTopicID = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        Store.remove(Self.sessionFile)
        // Let the app that was playing before carry on.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Drops the AVPlayer with its item and observers; the next chapter load
    /// builds a new one.
    private func tearDownPlayer() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver); self.failObserver = nil }
        timeControlObservation = nil
        itemStatusObservation = nil
        pendingResumeTime = nil
        cancelSeeks()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    /// The topic's downloaded files are being deleted: a chapter playing from
    /// one carries on from the stream (or another downloaded copy), where it was.
    func downloadsRemoved(topicID: Int) {
        guard topic?.id == topicID,
              (player?.currentItem?.asset as? AVURLAsset)?.url.isFileURL == true else { return }
        play(index: currentIndex, at: currentTime, autoplay: isPlaying)
    }

    /// A chapter whose stream never gets ready (a server that neither answers nor
    /// errors) ends in the error state, not an endless spinner.
    private func scheduleLoadTimeout() {
        let generation = seekGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, generation == self.seekGeneration,
                  self.pendingResumeTime != nil, self.isPlaying else { return }
            self.fail(String(localized: "The lecture is taking too long to load"))
        }
    }

    func next() {
        guard let topic else { return }
        if currentIndex + 1 < topic.lectures.count {
            play(index: currentIndex + 1)
        } else {
            pause()
        }
    }

    /// Called when a chapter finishes playing on its own.
    private func handleTrackEnd() {
        guard let topic else { return }
        // The status observer has usually cleared `isPlaying` already, so `pause()`
        // would do nothing here — stop and save explicitly, at the chapter's end.
        if duration > 0 { currentTime = duration }
        let lastChapter = currentIndex + 1 >= topic.lectures.count
        if sleepMode == .endOfChapter || lastChapter {
            pausedAt = Date()
            topicEnded = lastChapter
            if sleepMode == .endOfChapter { setSleep(.off) }   // also restores the faded volume
            stopInPlace()
            return
        }
        next()
    }

    /// Halts playback where it stands, keeping the topic loaded (unlike `stop()`),
    /// and publishes it to the lock screen and the saved progress. Callers set
    /// their own state first. `droppingItem` also unloads the current item.
    private func stopInPlace(droppingItem: Bool = false) {
        player?.pause()
        if droppingItem { player?.replaceCurrentItem(with: nil) }
        isPlaying = false
        isBuffering = false
        updateNowPlaying()
        persistProgress()
    }

    func previous() {
        if currentTime > 3 {
            seek(to: 0)
        } else if currentIndex > 0 {
            play(index: currentIndex - 1)
        } else {
            seek(to: 0)
        }
    }

    /// Invalidates in-flight seek completions (a new item or a stop owns the state).
    private func cancelSeeks() {
        isSeeking = false
        seekGeneration += 1
    }

    /// Seeks within the current chapter. Exact (zero tolerance): the default
    /// tolerance lets AVPlayer land seconds away from the target on MP3 streams,
    /// which made rewinding feel random.
    func seek(to time: Double) {
        guard topic != nil else { return }
        let t = max(0, duration > 0 ? min(time, duration) : time)
        currentTime = t
        if duration <= 0 || t < duration { topicEnded = false }
        updateNowPlayingElapsed()
        // Not loaded yet (brought back from the last launch): play starts here.
        guard let player else { persistProgress(); return }
        // Item not ready yet: retarget the pending start instead of issuing a seek
        // AVPlayer would drop (and that the start seek would then override).
        if pendingResumeTime != nil {
            pendingResumeTime = t
            return
        }
        isSeeking = true
        seekGeneration += 1
        let generation = seekGeneration
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A newer seek superseded this one — it owns the state now.
                    guard let self, generation == self.seekGeneration else { return }
                    self.isSeeking = false
                    if finished, let now = self.player?.currentTime().seconds, now.isFinite {
                        self.currentTime = now
                    }
                    self.updateNowPlaying()
                    // Paused: save now (no ticks will). Playing: let the next tick
                    // save, so a burst of skips costs one write, not one each.
                    if self.isPlaying { self.lastSave = .distantPast } else { self.persistProgress() }
                }
            }
        }
    }

    /// Jumps by `seconds`, crossing chapter boundaries: rewinding past a chapter's
    /// start continues into the end of the previous chapter, and skipping past its
    /// end lands in the next one — instead of sticking at 0:00 / the end.
    func skip(_ seconds: Double) {
        guard let topic else { return }
        switch PlaybackMath.skip(by: seconds, from: currentTime, index: currentIndex,
                                 currentDuration: duration,
                                 durations: topic.lectures.map(\.duration)) {
        case .seek(let t):
            seek(to: t)
        case .chapter(let index, let time):
            play(index: index, at: time, autoplay: isPlaying)
        }
    }

    /// Sets the speed for the loaded topic (remembered for that topic only).
    func setRate(_ r: Float) {
        let r = RateTopic.normalized(r)
        if let topic {
            rates.set(r, for: topic.id)
            persistTopicRates()
        }
        applyRate(r)
    }

    /// One fine step faster (+1) or slower (−1).
    func stepRate(_ direction: Int) {
        setRate(rate + Float(direction) * RateTopic.step)
    }

    /// True when the loaded topic has a speed of its own.
    var hasTopicRate: Bool { rates.hasOwnRate(topic?.id) }

    /// Drops the loaded topic's own speed — back to the default.
    func resetTopicRate() {
        guard let topic else { return }
        rates.reset(topic.id)
        persistTopicRates()
        applyRate(defaultRate)
    }

    /// The Settings default, for topics without a speed of their own.
    func setDefaultRate(_ r: Float) {
        rates.defaultRate = RateTopic.normalized(r)
        UserDefaults.standard.set(Double(defaultRate), forKey: Self.rateKey)
        if !hasTopicRate { applyRate(defaultRate) }
    }

    private func persistTopicRates() {
        UserDefaults.standard.set(rates.perTopic, forKey: Self.topicRatesKey)
    }

    /// VoiceOver label for the skip buttons, from the Settings step.
    func skipLabel(forward: Bool) -> String {
        forward ? String(localized: "Forward \(Int(skipForward)) seconds") : String(localized: "Back \(Int(skipBack)) seconds")
    }
    func skip(forward: Bool) { skip(forward ? skipForward : -skipBack) }

    private func applyRate(_ r: Float) {
        rate = r
        if isPlaying, pendingResumeTime == nil { player?.rate = r }
        updateNowPlaying()
    }

    /// Jumps to a position anywhere in the topic (bookmarks) and plays.
    func jump(index: Int, time: Double) {
        if index == currentIndex, player != nil, playbackError == nil {
            seek(to: time)
            if !isPlaying { pausedAt = nil; play() }
        } else {
            play(index: index, at: time)
        }
    }

    func setSkip(back: Double? = nil, forward: Double? = nil) {
        if let back { skipBack = back; UserDefaults.standard.set(back, forKey: Self.skipBackKey) }
        if let forward { skipForward = forward; UserDefaults.standard.set(forward, forKey: Self.skipForwardKey) }
        updateSkipIntervals()
    }

    func setSmartRewind(_ on: Bool) {
        smartRewind = on
        UserDefaults.standard.set(on, forKey: Self.smartRewindKey)
    }

    /// Keeps the lock-screen skip arrows in step with the Settings choice.
    private func updateSkipIntervals() {
        let c = MPRemoteCommandCenter.shared()
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBack)]
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForward)]
    }

    // MARK: - Sleep timer

    func setSleep(_ mode: SleepMode) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTarget = nil
        sleepMode = mode
        sleepFired = nil
        player?.volume = 1
        updateShakeDetection()
        switch mode {
        case .off, .endOfChapter:
            sleepRemaining = nil
        case .minutes(let m):
            let target = Date().addingTimeInterval(TimeInterval(m * 60))
            sleepTarget = target
            sleepRemaining = TimeInterval(m * 60)
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickSleep() }
            }
            RunLoop.main.add(timer, forMode: .common)
            sleepTimer = timer
        }
    }

    /// Length of the fade-out before the sleep timer pauses.
    private static let sleepFade: TimeInterval = 10

    private func tickSleep() {
        guard let target = sleepTarget else { return }
        let remaining = target.timeIntervalSinceNow
        if remaining <= 0 {
            let minutes: Int? = if case .minutes(let m) = sleepMode { m } else { nil }
            pause()
            setSleep(.off)
            if let minutes {
                sleepFired = (Date(), minutes)
                updateShakeDetection()
                // Stop listening once the "shake to resume" window has passed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 121) { [weak self] in
                    MainActor.assumeIsolated { self?.updateShakeDetection() }
                }
            }
        } else {
            // Publish whole seconds only — the labels show nothing finer, and every
            // clock publish redraws all the time UI.
            if Int(remaining) != sleepRemaining.map(Int.init) { sleepRemaining = remaining }
            // Fade out over the last seconds instead of cutting off mid-word.
            if remaining <= Self.sleepFade { player?.volume = Float(remaining / Self.sleepFade) }
        }
    }

    /// Starts/stops the accelerometer to match whether a shake would do anything.
    private func updateShakeDetection() {
        var wanted = false
        if case .minutes = sleepMode { wanted = true }
        if let fired = sleepFired, Date().timeIntervalSince(fired.at) < 120 { wanted = true }
        guard motion.isAccelerometerAvailable else { return }
        if wanted, !motion.isAccelerometerActive {
            motion.accelerometerUpdateInterval = 0.1
            motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let a = data?.acceleration else { return }
                // ~1g at rest; a real shake spikes well above 2.5g.
                guard (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot() > 2.5 else { return }
                MainActor.assumeIsolated {
                    guard let self, Date().timeIntervalSince(self.lastShake) > 1.5 else { return }
                    self.lastShake = Date()
                    if self.handleShake() {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                }
            }
        } else if !wanted, motion.isAccelerometerActive {
            motion.stopAccelerometerUpdates()
        }
    }

    /// Shake gesture: while a minutes timer runs, add 10 minutes; shortly after it
    /// fired, resume and restart the same timer. Returns whether it did anything.
    @discardableResult
    func handleShake() -> Bool {
        if case .minutes = sleepMode, let target = sleepTarget {
            sleepTarget = target.addingTimeInterval(10 * 60)
            sleepRemaining = sleepTarget?.timeIntervalSinceNow
            player?.volume = 1
            return true
        }
        if let fired = sleepFired, Date().timeIntervalSince(fired.at) < 120, topic != nil {
            play()
            setSleep(.minutes(fired.minutes))
            return true
        }
        return false
    }

    // MARK: - Audio session

    /// The category is set at launch, but the session only becomes active once
    /// something plays: opening the app to browse mustn't stop other apps' audio.
    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)

        // Pause on a phone call / Siri and resume afterwards if the system asks;
        // pause when headphones are unplugged. Without these, `isPlaying` would
        // drift out of sync with the actual (system-paused) player.
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        })
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// The system's media server restarted (it happens with Bluetooth and
    /// CarPlay): the session and player are dead. Set up again and reload the
    /// chapter where it was, paused.
    private func handleMediaServicesReset() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        guard topic != nil else { return }
        let index = currentIndex, time = currentTime
        tearDownPlayer()
        play(index: index, at: time, autoplay: false)
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // The status observer may have seen the system pause first and cleared
            // `isPlaying`; a pause it saw just now still counts as playing.
            let recent = externalPauseAt.map { Date().timeIntervalSince($0) < 2 } ?? false
            resumeAfterInterruption = isPlaying || recent
            if isPlaying { pause() } else { persistProgress() }
        case .ended:
            let wasPlaying = resumeAfterInterruption
            resumeAfterInterruption = false
            guard wasPlaying, let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            if AVAudioSession.InterruptionOptions(rawValue: optsRaw).contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                play()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Old output device gone (e.g. headphones unplugged) → pause, like the
        // system Music app, instead of blasting audio from the speaker.
        if reason == .oldDeviceUnavailable {
            pause()
            // Not a pause an interruption should undo onto the speaker.
            externalPauseAt = nil
        }
    }

    // MARK: - Observers

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // The observer is bound to .main, so execution really is on the main actor.
            MainActor.assumeIsolated {
                guard let self else { return }
                // While a chapter loads or a seek is in flight the player reports a
                // stale position; the clock already holds the target.
                guard self.pendingResumeTime == nil, !self.isSeeking else { return }
                let t = time.seconds
                guard t.isFinite else { return }
                // The lock screen runs its own clock from the rate; it's updated
                // on play, pause, seeks and stalls rather than every tick.
                self.currentTime = t
                // "Until end of chapter" fades out over the chapter's last seconds.
                if self.sleepMode == .endOfChapter, self.duration > 0 {
                    let left = self.duration - t
                    self.player?.volume = Float(min(max(left / Self.sleepFade, 0), 1))
                }
                // Save progress no more than once every 5 seconds.
                if self.topic != nil, Date().timeIntervalSince(self.lastSave) > 5 {
                    self.persistProgress()
                }
            }
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        let center = NotificationCenter.default
        if let endObserver { center.removeObserver(endObserver) }
        if let failObserver { center.removeObserver(failObserver) }
        endObserver = center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleTrackEnd() }
        }
        // A stream that dies mid-chapter (network lost for good) — surface it
        // instead of leaving a frozen progress bar behind an endless spinner.
        failObserver = center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription
            Task { @MainActor in self?.fail(message) }
        }
    }

    /// Puts the player into the visible error state.
    private func fail(_ message: String?) {
        pendingResumeTime = nil
        isSeeking = false
        player?.pause()
        isPlaying = false
        isBuffering = false
        playbackError = message ?? String(localized: "Couldn’t play the lecture")
        updateNowPlaying()
        persistProgress()
    }

    /// Derive `isPlaying`/`isBuffering` from the player's real state instead of a
    /// manual flag, so buffering and stalls (e.g. lost network) no longer show a
    /// fake "playing" with no sound.
    private func observeTimeControlStatus() {
        timeControlObservation = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            // KVO calls back on whichever thread changed it, which needn't be main.
            DispatchQueue.main.async { MainActor.assumeIsolated {
                // While a chapter loads, the player is deliberately paused and
                // `isPlaying` holds the user's intent — don't let that flip it.
                guard let self, self.pendingResumeTime == nil else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.isPlaying = true
                    self.isBuffering = false
                case .waitingToPlayAtSpecifiedRate:
                    self.isBuffering = true
                case .paused:
                    // Paused from outside (another app took the audio, etc.) —
                    // still counts as a break for the smart rewind.
                    if self.isPlaying {
                        self.pausedAt = Date()
                        self.externalPauseAt = Date()
                    }
                    self.isPlaying = false
                    self.isBuffering = false
                @unknown default:
                    break
                }
                self.updateNowPlaying()
            } }
        }
    }

    /// Observe the current item: apply the deferred resume seek once ready, and
    /// surface a load failure (broken/404 stream) as a visible error instead of a
    /// stuck pause.
    private func observeStatus(of item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, item === self.player?.currentItem else { return }
                    self.handleStatus(of: item)
                }
            }
        }
    }

    /// Ready → apply the real duration, position the item at its start time, then
    /// play if the user still wants it. Failed → visible error.
    private func handleStatus(of item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            guard let target = pendingResumeTime, !startIssued else { return }
            startIssued = true
            // The real length can differ from the page's metadata; the scrubber
            // and skips must use what the file actually holds.
            let real = item.duration.seconds
            if real.isFinite, real > 0 { duration = real }
            let generation = seekGeneration
            let begin = { [weak self] in
                // Superseded by another chapter load or a stop meanwhile.
                guard let self, generation == self.seekGeneration,
                      let latest = self.pendingResumeTime else { return }
                self.pendingResumeTime = nil
                if self.isPlaying {
                    self.player?.playImmediately(atRate: self.rate)
                } else {
                    self.isBuffering = false
                }
                // The user moved the position while the start seek was running.
                if abs(latest - target) > 0.5 { self.seek(to: latest) }
                self.updateNowPlaying()
            }
            if target > 0 {
                player?.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { begin() } }
                }
            } else {
                begin()
            }
        case .failed:
            fail(item.error?.localizedDescription)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Now Playing / lock screen

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        /// Runs `action` on the loaded topic; with none (iOS relaunched the app
        /// and the headphones said play), says so instead of claiming success.
        func onTopic(_ action: @escaping (AudioPlayer, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus)
            -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
            { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.topic != nil else { return .noActionableNowPlayingItem }
                    return action(self, event)
                }
            }
        }
        c.playCommand.addTarget(handler: onTopic { p, _ in p.play(); return .success })
        c.pauseCommand.addTarget(handler: onTopic { p, _ in p.pause(); return .success })
        c.togglePlayPauseCommand.addTarget(handler: onTopic { p, _ in p.togglePlayPause(); return .success })
        c.nextTrackCommand.addTarget(handler: onTopic { p, _ in p.next(); return .success })
        c.previousTrackCommand.addTarget(handler: onTopic { p, _ in p.previous(); return .success })
        c.changePlaybackRateCommand.supportedPlaybackRates = Self.ratePresets.map { NSNumber(value: $0) }
        c.changePlaybackRateCommand.addTarget(handler: onTopic { p, event in
            guard let e = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            p.setRate(e.playbackRate)
            return .success
        })

        // Show seek arrows (the Settings step) on the lock screen. iOS hides the
        // lecture prev/next buttons whenever the skip commands are enabled, so we get
        // the skip arrows instead of the chapter buttons.
        updateSkipIntervals()
        c.skipForwardCommand.isEnabled = true
        c.skipBackwardCommand.isEnabled = true
        c.skipForwardCommand.addTarget(handler: onTopic { p, event in
            guard let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            p.skip(e.interval)
            return .success
        })
        c.skipBackwardCommand.addTarget(handler: onTopic { p, event in
            guard let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            p.skip(-e.interval)
            return .success
        })

        c.changePlaybackPositionCommand.addTarget(handler: onTopic { p, event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            p.seek(to: e.positionTime)
            return .success
        })
    }

    private func updateNowPlaying() {
        guard let topic, let lecture = currentLecture else { return }
        // Another topic: start afresh, so the previous one's cover doesn't linger.
        var info = nowPlayingTopicID == topic.id ? MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:] : [:]
        nowPlayingTopicID = topic.id
        info[MPMediaItemPropertyTitle] = "\(topic.title) — \(lecture.displayTitle(at: currentIndex))"
        info[MPMediaItemPropertyArtist] = topic.lecturer
        info[MPMediaItemPropertyAlbumTitle] = loadedSummary?.group?.name
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = lockScreenRate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        updateTrackCommands()
    }

    /// Enables the lock-screen prev/next-lecture buttons only when such a chapter
    /// exists, so the controls reflect the position within the topic.
    private func updateTrackCommands() {
        let c = MPRemoteCommandCenter.shared()
        let count = topic?.lectures.count ?? 0
        c.nextTrackCommand.isEnabled = currentIndex + 1 < count
        c.previousTrackCommand.isEnabled = currentIndex > 0
    }

    private func updateNowPlayingElapsed() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = lockScreenRate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// The rate the lock screen's clock runs at: stopped while buffering, so it
    /// doesn't run ahead of the sound.
    private var lockScreenRate: Float { isPlaying && !isBuffering ? rate : 0 }

    /// The topic's cover on the lock screen: the downloaded copy when there is one
    /// (works offline), else the remote image. Loaded once per topic: the info
    /// starts afresh on a topic change, so artwork already there is this topic's.
    private func loadArtwork() {
        let center = MPNowPlayingInfoCenter.default()
        guard let topic,
              nowPlayingTopicID != topic.id || center.nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil,
              let url = DownloadManager.shared.coverURL(for: topic) else { return }
        let topicID = topic.id
        Task {
            // Read and decode off the main actor — playback is just starting.
            let image = await Task.detached(priority: .utility) { () -> UIImage? in
                if url.isFileURL {
                    return UIImage(contentsOfFile: url.path)?.preparingForDisplay()
                }
                guard let (_, data) = await [url].firstAvailableData() else { return nil }
                return UIImage(data: data)?.preparingForDisplay()
            }.value
            guard let image else { return }
            // The topic may have changed while the cover was loading — don't let
            // a stale image overwrite the current topic's artwork.
            guard self.topic?.id == topicID, self.nowPlayingTopicID == topicID else { return }
            let art = Self.artwork(image)
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = art
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    /// Built outside the main actor: MediaPlayer asks for the image on its own
    /// queue.
    private nonisolated static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
