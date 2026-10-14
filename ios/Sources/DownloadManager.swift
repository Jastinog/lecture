import Foundation
import Network
import os

/// Paths for offline storage: Application Support/Downloads/<bookId>/...
enum DownloadPaths {
    /// Kept out of iCloud and iTunes backups: the lectures can always be
    /// downloaded again, and a few topics run to gigabytes.
    static let base: URL = {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()
    /// The topic's folder. Not created here: only saving a topic makes it, so a late
    /// transfer or size scan can't bring back a folder the user just deleted.
    static func topicDir(_ topicID: Int) -> URL {
        base.appendingPathComponent("\(topicID)", isDirectory: true)
    }
    static func createTopicDir(_ topicID: Int) throws {
        try FileManager.default.createDirectory(at: topicDir(topicID), withIntermediateDirectories: true)
    }
    static func lectureFile(_ topicID: Int, _ lectureID: Int) -> URL {
        topicDir(topicID).appendingPathComponent("\(lectureID).mp3")
    }
    static func topicJSON(_ topicID: Int) -> URL { topicDir(topicID).appendingPathComponent("topic.json") }
    static func cover(_ topicID: Int) -> URL { topicDir(topicID).appendingPathComponent("cover.jpg") }
}

/// Resume data of downloads cut off part way (the app force-quit, a dropped
/// transfer), kept on disk so they continue after a relaunch instead of
/// starting over. Downloads/.resume/<topic>:<lecture>; the launch scan skips
/// the folder, its name not being a topic id.
@MainActor
enum ResumeData {
    private static let dir: URL = {
        let dir = DownloadPaths.base.appendingPathComponent(".resume", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The downloads that have some: the folder is listed once, so starting a
    /// download with none doesn't touch the disk.
    private(set) static var keys: Set<DownloadKey> = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.compactMap(DownloadKey.init))
    }()

    private static func file(_ key: DownloadKey) -> URL { dir.appendingPathComponent(key.description) }

    static func save(_ data: Data, for key: DownloadKey) {
        if (try? data.write(to: file(key), options: .atomic)) != nil { keys.insert(key) }
    }

    /// The download's resume data, if any, removed from the disk: it's good
    /// for one task.
    static func take(_ key: DownloadKey) -> Data? {
        guard keys.contains(key) else { return nil }
        defer { discard(key) }
        return try? Data(contentsOf: file(key))
    }

    static func discard(_ key: DownloadKey) {
        guard keys.remove(key) != nil else { return }
        try? FileManager.default.removeItem(at: file(key))
    }

    static func discard(topicID: Int) {
        for key in keys where key.topicID == topicID { discard(key) }
    }
}

/// One lecture's download into one topic. The same lecture can be in a topic and
/// in a selection (a topic with a negative id), each downloading its own copy.
struct DownloadKey: Hashable {
    let topicID: Int
    let lectureID: Int

    /// What a task carries in its `taskDescription`, to be found after a relaunch.
    var description: String { "\(topicID):\(lectureID)" }

    init(_ topicID: Int, _ lectureID: Int) {
        self.topicID = topicID
        self.lectureID = lectureID
    }

    init?(_ description: String?) {
        guard let parts = description?.split(separator: ":"), parts.count == 2,
              let topicID = Int(parts[0]), let lectureID = Int(parts[1]) else { return nil }
        self.init(topicID, lectureID)
    }
}

/// Live per-chapter download progress. See `DownloadManager.live`.
@MainActor
final class DownloadProgress: ObservableObject {
    @Published fileprivate(set) var values: [DownloadKey: Double] = [:]

    func value(_ topicID: Int, _ lectureID: Int) -> Double? { values[DownloadKey(topicID, lectureID)] }

    /// Any of the topic's lectures coming in.
    func isDownloading(_ topic: TopicDetail) -> Bool {
        topic.lectures.contains { value(topic.id, $0.id) != nil }
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    /// topicID -> set of downloaded trackIDs.
    @Published private(set) var downloaded: [Int: Set<Int>] = [:]
    /// Active download progress (0…1) per lecture. Published on its own object so
    /// the 1%-step updates (constant while a topic downloads) redraw only the
    /// download indicators, not every screen that observes the manager.
    let live = DownloadProgress()
    /// Saved topics (for the offline library).
    @Published private(set) var savedTopics: [Int: TopicDetail] = [:] {
        didSet { library = savedTopics.values.sorted { $0.title < $1.title } }
    }
    /// Sorted snapshot of `savedTopics`, rebuilt only on change — so list rows and
    /// `onDelete` index into a stable array, not a per-access re-sort.
    @Published private(set) var library: [TopicDetail] = []
    /// Bytes on disk per topic, and in total (refreshed after changes).
    @Published private(set) var topicSizes: [Int: Int64] = [:]
    var totalSize: Int64 { topicSizes.values.reduce(0, +) }

    private var activeTasks: [DownloadKey: URLSessionDownloadTask] = [:]
    /// Tasks started from resume data: should one fail, the lecture is
    /// downloaded again from the start before anything is reported.
    private var resumedTasks: Set<ObjectIdentifier> = []
    /// Downloads that failed since the last alert about it, and whether one
    /// failed for want of space. Reported once the batch settles.
    private var failures = 0
    private var outOfSpace = false
    private var failureReport: Task<Void, Never>?
    /// Set by the app delegate when iOS relaunches us to deliver finished
    /// background transfers, per session; called once all its events are processed.
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]

    /// Downloads may use cellular data; when off they wait for Wi-Fi (Settings).
    @Published private(set) var cellularAllowed: Bool
    private static let cellularKey = "lecture.downloadOverCellular"

    /// One background session per network policy: a task's cellular access can't
    /// be changed once it runs, so changing the setting moves the downloads under
    /// way to the other session. Background sessions survive backgrounding / app
    /// termination and are handed back via `handleEventsForBackgroundURLSession`.
    private lazy var cellularSession = makeSession("com.personal.vuhe.downloads", cellular: true)
    private lazy var wifiSession = makeSession("com.personal.vuhe.downloads.wifi", cellular: false)
    /// The session new downloads go to.
    private var session: URLSession { cellularAllowed ? cellularSession : wifiSession }

    /// Whether the phone is on Wi-Fi (or wired) right now, to say why a
    /// Wi-Fi-only download isn't moving.
    private let pathMonitor = NWPathMonitor()

    static let userAgent = "Mozilla/5.0 (iPhone)"

    private override init() {
        cellularAllowed = UserDefaults.standard.object(forKey: Self.cellularKey) as? Bool ?? true
        super.init()
        // Downloads happen only when asked for: drop what the old "Download
        // Next Lectures" setting left behind.
        UserDefaults.standard.removeObject(forKey: "lecture.autoDownload")
        UserDefaults.standard.removeObject(forKey: "lecture.autoDownloadWiFiOnly")
        pathMonitor.start(queue: DispatchQueue(label: "downloads.path"))
        // Create the background sessions now, not lazily, so transfers that outlived
        // the last launch reconnect and report to us.
        _ = (cellularSession, wifiSession)
        Task {
            await loadDiskContents()
            await adoptRunningTasks()
            await applyCellularPolicy()
            resumeInterrupted()
            refreshSizes()
        }
    }

    /// Capped to a few connections per host so a 50-chapter topic doesn't fire 50
    /// requests at once (throttle / ban risk).
    private func makeSession(_ identifier: String, cellular: Bool) -> URLSession {
        let c = URLSessionConfiguration.background(withIdentifier: identifier)
        c.httpAdditionalHeaders = ["User-Agent": DownloadManager.userAgent]
        c.httpMaximumConnectionsPerHost = 3
        c.allowsCellularAccess = cellular
        // Relaunch the app to deliver finished transfers — an iOS-only concept.
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }

    /// Settings: download over cellular, or only on Wi-Fi.
    func setCellularAllowed(_ allowed: Bool) {
        guard allowed != cellularAllowed else { return }
        cellularAllowed = allowed
        UserDefaults.standard.set(allowed, forKey: Self.cellularKey)
        Task { await applyCellularPolicy() }
    }

    /// Downloaded topics the listener has finished (and isn't playing right now).
    var finishedTopics: [TopicDetail] {
        let playing = AudioPlayer.shared.topic?.id
        return library.filter { $0.id != playing && ProgressStore.isFinished(topicID: $0.id) }
    }

    func deleteFinished() {
        for topic in finishedTopics { deleteTopic(topic.id) }
    }

    /// Re-measures topic folders off the main thread — `ids` only, or all topics —
    /// publishing only if something changed.
    func refreshSizes(_ ids: [Int]? = nil) {
        let ids = ids ?? Array(savedTopics.keys)
        Task {
            let measured = await Task.detached(priority: .utility) {
                ids.map { ($0, Self.folderSize(DownloadPaths.topicDir($0))) }
            }.value
            var sizes = topicSizes
            for (id, size) in measured where savedTopics[id] != nil { sizes[id] = size }
            if sizes != topicSizes { topicSizes = sizes }
        }
    }

    private nonisolated static func folderSize(_ dir: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// Coalesces size refreshes while a batch of chapters finishes downloading;
    /// only the topics that changed are re-measured.
    private var sizeRefresh: Task<Void, Never>?
    private var staleSizes: Set<Int> = []
    private func scheduleSizeRefresh(_ topicID: Int) {
        staleSizes.insert(topicID)
        sizeRefresh?.cancel()
        sizeRefresh = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            refreshSizes(Array(staleSizes))
            staleSizes = []
        }
    }

    /// Reattaches to the background session and stores the completion handler iOS
    /// passes when relaunching to deliver finished transfers. Reaching `shared`
    /// has connected both background sessions, so their delegate callbacks fire
    /// for the pending events.
    func handleBackgroundEvents(session identifier: String, completionHandler: @escaping () -> Void) {
        backgroundCompletionHandlers[identifier] = completionHandler
    }

    /// Takes back the transfers still running in the background session from an
    /// earlier launch, so they show progress, block duplicates and can be
    /// cancelled. Ones for topics no longer saved (or already on disk) are dropped.
    private func adoptRunningTasks() async {
        for session in [cellularSession, wifiSession] {
            for case let task as URLSessionDownloadTask in await session.allTasks {
                guard let key = DownloadKey(task.taskDescription) else { task.cancel(); continue }
                if activeTasks[key] === task { continue }   // queued this launch
                guard savedTopics[key.topicID] != nil, !isDownloaded(key.topicID, key.lectureID),
                      activeTasks[key] == nil else { task.cancel(); continue }
                activeTasks[key] = task
                let expected = task.countOfBytesExpectedToReceive
                live.values[key] = expected > 0 ? Double(task.countOfBytesReceived) / Double(expected) : 0
            }
        }
    }

    /// Moves the downloads in the other session over to the one the setting
    /// calls for, each continuing from where it got to.
    private func applyCellularPolicy() async {
        let other = cellularAllowed ? wifiSession : cellularSession
        for task in await other.allTasks {
            // Ones not adopted yet are left to the launch pass, which adopts or drops them.
            guard let key = DownloadKey(task.taskDescription), activeTasks[key] === task,
                  let url = task.originalRequest?.url else { continue }
            // Its cancel callback no longer counts: the key is free for the new task.
            activeTasks[key] = nil
            (task as? URLSessionDownloadTask)?.cancel(byProducingResumeData: { data in
                Task { @MainActor in self.restart(key, url: url, resumeData: data) }
            })
        }
    }

    /// Picks a moved download up again, unless it was cancelled or its topic
    /// deleted while the old task wound down.
    private func restart(_ key: DownloadKey, url: URL, resumeData: Data?) {
        guard live.values[key] != nil, activeTasks[key] == nil, savedTopics[key.topicID] != nil,
              !isDownloaded(key.topicID, key.lectureID) else { return }
        start(key, url: url, resumeData: resumeData)
    }

    /// Continues the downloads a force-quit (or a dropped transfer) cut off in an
    /// earlier launch.
    private func resumeInterrupted() {
        for key in ResumeData.keys where activeTasks[key] == nil {
            guard let topic = savedTopics[key.topicID],
                  let lecture = topic.lectures.first(where: { $0.id == key.lectureID }),
                  !isDownloaded(key.topicID, key.lectureID) else {
                ResumeData.discard(key)
                continue
            }
            enqueue(topic: topic, lecture: lecture)
        }
    }

    // MARK: - State queries

    func isDownloaded(_ topicID: Int, _ lectureID: Int) -> Bool {
        downloaded[topicID]?.contains(lectureID) ?? false
    }
    func downloadedCount(_ topicID: Int) -> Int { downloaded[topicID]?.count ?? 0 }
    func isTopicDownloading(_ topic: TopicDetail) -> Bool {
        topic.lectures.contains { activeTasks[DownloadKey(topic.id, $0.id)] != nil }
    }
    func isFullyDownloaded(_ topic: TopicDetail) -> Bool {
        downloadedCount(topic.id) == topic.lectures.count && topic.lectures.count > 0
    }
    /// How much of the topic is on the phone, counting the part of each lecture
    /// still coming in.
    func topicFraction(_ topic: TopicDetail) -> Double {
        guard !topic.lectures.isEmpty else { return 0 }
        let partial = topic.lectures.reduce(0.0) { $0 + (live.value(topic.id, $1.id) ?? 0) }
        return (Double(downloadedCount(topic.id)) + partial) / Double(topic.lectures.count)
    }

    /// Local chapter file, if downloaded: the topic's own copy, or one saved with
    /// another topic or selection, so a lecture downloaded from its topic plays
    /// offline from a selection too. Looks at the disk, not only at what the
    /// launch scan has found so far, for a play pressed right after a cold start.
    func localLectureURL(topicID: Int, lectureID: Int) -> URL? {
        let fm = FileManager.default
        let own = DownloadPaths.lectureFile(topicID, lectureID)
        if fm.fileExists(atPath: own.path) { return own }
        return downloaded.lazy
            .filter { $0.key != topicID && $0.value.contains(lectureID) }
            .map { DownloadPaths.lectureFile($0.key, lectureID) }
            .first { fm.fileExists(atPath: $0.path) }
    }

    /// Cover: local if present, otherwise the remote URL.
    func coverURL(for topic: TopicDetail) -> URL? {
        let f = DownloadPaths.cover(topic.id)
        return FileManager.default.fileExists(atPath: f.path) ? f : topic.coverURL
    }

    // MARK: - Actions

    /// Download a whole topic (missing chapters).
    func downloadTopic(_ topic: TopicDetail) {
        guard ensureSaved(topic) else { return }
        for lecture in topic.lectures where !isDownloaded(topic.id, lecture.id) {
            enqueue(topic: topic, lecture: lecture)
        }
        noteWaitingForWiFi()
    }

    /// Download a single chapter.
    func downloadLecture(topic: TopicDetail, lecture: Lecture) {
        guard ensureSaved(topic) else { return }
        guard !isDownloaded(topic.id, lecture.id) else { return }
        enqueue(topic: topic, lecture: lecture)
        noteWaitingForWiFi()
    }

    /// On cellular with downloads kept to Wi-Fi, the new ones won't move: say
    /// why, once per launch.
    private var toldWaitingForWiFi = false
    private func noteWaitingForWiFi() {
        let path = pathMonitor.currentPath
        guard !cellularAllowed, !toldWaitingForWiFi, path.status == .satisfied,
              !path.usesInterfaceType(.wifi), !path.usesInterfaceType(.wiredEthernet) else { return }
        toldWaitingForWiFi = true
        Alerts.shared.show(String(localized: "Waiting for Wi-Fi"),
                           message: String(localized: "Downloads will start when the iPhone connects to Wi-Fi. To use cellular data, turn it on in Settings."))
    }

    /// Cancel the topic's active downloads.
    func cancelTopic(_ topic: TopicDetail) {
        for lecture in topic.lectures { cancelLecture(topicID: topic.id, lectureID: lecture.id) }
    }

    /// Cancel one chapter's download.
    func cancelLecture(topicID: Int, lectureID: Int) {
        let key = DownloadKey(topicID, lectureID)
        activeTasks.removeValue(forKey: key)?.cancel()
        live.values[key] = nil
        ResumeData.discard(key)
    }

    /// Remove the whole topic from downloads. A chapter playing from it carries
    /// on from the stream.
    func deleteTopic(_ topicID: Int) {
        if let topic = savedTopics[topicID] { cancelTopic(topic) }
        try? FileManager.default.removeItem(at: DownloadPaths.topicDir(topicID))
        downloaded[topicID] = nil
        savedTopics[topicID] = nil
        topicSizes[topicID] = nil
        ResumeData.discard(topicID: topicID)
        AudioPlayer.shared.downloadsRemoved(topicID: topicID)
    }

    /// Remove one lecture from downloads; the topic goes too once nothing of
    /// it is left on the phone or coming in. Playing from the file, it carries
    /// on from the stream.
    func deleteLecture(topicID: Int, lectureID: Int) {
        cancelLecture(topicID: topicID, lectureID: lectureID)
        try? FileManager.default.removeItem(at: DownloadPaths.lectureFile(topicID, lectureID))
        downloaded[topicID]?.remove(lectureID)
        if downloaded[topicID]?.isEmpty == true { downloaded[topicID] = nil }
        if downloaded[topicID] == nil, let topic = savedTopics[topicID], !live.isDownloading(topic) {
            deleteTopic(topicID)
            return
        }
        scheduleSizeRefresh(topicID)
        AudioPlayer.shared.downloadsRemoved(topicID: topicID, lectureID: lectureID)
    }

    // MARK: - Internals

    private func enqueue(topic: TopicDetail, lecture: Lecture) {
        let key = DownloadKey(topic.id, lecture.id)
        guard activeTasks[key] == nil else { return }   // already on its way
        // Already on the phone with another topic: a clone of that file costs
        // no space on APFS, and no download.
        if let other = localLectureURL(topicID: topic.id, lectureID: lecture.id),
           (try? FileManager.default.copyItem(at: other, to: DownloadPaths.lectureFile(topic.id, lecture.id))) != nil {
            downloaded[topic.id, default: []].insert(lecture.id)
            scheduleSizeRefresh(topic.id)
            return
        }
        // Only download over https (the URL comes from inline page JS).
        guard lecture.url.scheme == "https" else { return }
        start(key, url: lecture.url)
    }

    /// Continues from where an interrupted download left off, if its resume data
    /// is kept; otherwise starts afresh.
    private func start(_ key: DownloadKey, url: URL, resumeData: Data? = nil) {
        if live.values[key] == nil { live.values[key] = 0 }
        let task: URLSessionDownloadTask
        if let data = resumeData ?? ResumeData.take(key) {
            task = session.downloadTask(withResumeData: data)
            resumedTasks.insert(ObjectIdentifier(task))
        } else {
            task = session.downloadTask(with: URLRequest(url: url))
        }
        task.taskDescription = key.description
        activeTasks[key] = task
        task.resume()
    }

    /// Saves the topic's metadata (and cover). False if `topic.json` couldn't be
    /// written — the chapters would be orphaned on the next launch, so the caller
    /// doesn't download them.
    @discardableResult
    private func ensureSaved(_ topic: TopicDetail) -> Bool {
        do {
            try DownloadPaths.createTopicDir(topic.id)
            try JSONEncoder().encode(topic).write(to: DownloadPaths.topicJSON(topic.id), options: .atomic)
        } catch {
            // Most likely the phone is full; say so rather than fail silently.
            Alerts.shared.show(String(localized: "Can’t Download"),
                               message: String(localized: "The topic couldn’t be saved on this iPhone."))
            return false
        }
        savedTopics[topic.id] = topic
        // cover — save the sharpest variant the site offers (original → -4 → thumb)
        // so offline topics look as crisp as the online detail hero.
        let coverFile = DownloadPaths.cover(topic.id)
        if !FileManager.default.fileExists(atPath: coverFile.path), let url = topic.coverURL {
            Task {
                if let (_, data) = await [url].firstAvailableData() {
                    // Atomic: a cut-off cover would stick, as it's only fetched when absent.
                    try? data.write(to: coverFile, options: .atomic)
                }
            }
        }
        return true
    }

    /// True if `task` is the chapter's current task — callbacks from a replaced
    /// or cancelled one arrive late and mustn't touch the new task's state. (By
    /// identity: task ids repeat across the two sessions.)
    private func isCurrent(_ key: DownloadKey, _ task: URLSessionTask) -> Bool {
        activeTasks[key] === task
    }

    fileprivate func markDownloaded(_ key: DownloadKey, task: URLSessionTask) {
        resumedTasks.remove(ObjectIdentifier(task))
        // The file is gone if the topic was deleted while the move hopped over here.
        guard FileManager.default.fileExists(atPath: DownloadPaths.lectureFile(key.topicID, key.lectureID).path)
        else { return }
        downloaded[key.topicID, default: []].insert(key.lectureID)
        ResumeData.discard(key)
        if activeTasks[key] == nil || isCurrent(key, task) {
            live.values[key] = nil
            activeTasks[key] = nil
        }
        scheduleSizeRefresh(key.topicID)
    }

    /// `error` is why, when it's worth telling the listener (not a cancel).
    fileprivate func markFailed(_ key: DownloadKey, task: URLSessionTask, resumeData: Data? = nil, error: Error? = nil) {
        let wasResumed = resumedTasks.remove(ObjectIdentifier(task)) != nil
        let current = isCurrent(key, task)
        // Resume data can go stale (the partial file purged, the file changed on
        // the server): download the lecture again from the start.
        if current, wasResumed, error != nil, let url = task.originalRequest?.url ?? task.currentRequest?.url {
            activeTasks[key] = nil
            start(key, url: url)
            return
        }
        // Resume data from a transfer cut off before this launch adopted it
        // (the app was force-quit) is still worth keeping for a retry.
        if let resumeData, activeTasks[key] == nil || current {
            ResumeData.save(resumeData, for: key)
        }
        guard current else { return }
        activeTasks[key] = nil
        live.values[key] = nil
        if let error { reportFailure(error) }
    }

    /// Collects failures and tells the listener once, when a batch has had a
    /// moment to settle: one alert for a topic whose every lecture failed.
    private func reportFailure(_ error: Error) {
        failures += 1
        let code = (error as NSError).code
        if code == NSFileWriteOutOfSpaceError || code == NSURLErrorCannotWriteToFile { outOfSpace = true }
        failureReport?.cancel()
        failureReport = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let message = outOfSpace
                ? String(localized: "There isn’t enough space on this iPhone. Free some up and try again.")
                : String(localized: "\(failures) lectures couldn’t be downloaded. Try again later.")
            failures = 0
            outOfSpace = false
            Alerts.shared.show(String(localized: "Download Failed"), message: message)
        }
    }

    fileprivate func setProgress(_ key: DownloadKey, task: URLSessionTask, _ value: Double) {
        guard isCurrent(key, task) else { return }
        live.values[key] = value
    }

    /// Scans disk off the main thread on startup, then publishes the result — so
    /// the directory walk + per-topic JSON decode no longer block launch on the main
    /// actor.
    private func loadDiskContents() async {
        let result = await Task.detached(priority: .utility) { Self.scanDiskContents() }.value
        var mergedBooks = savedTopics
        for (id, topic) in result.topics where mergedBooks[id] == nil { mergedBooks[id] = topic }
        savedTopics = mergedBooks   // single didSet → one library rebuild
        // Union: a chapter that finished while the scan ran is already recorded.
        for (id, ids) in result.downloaded { downloaded[id, default: []].formUnion(ids) }
    }

    /// Pure disk scan (no actor state). Only registers a topic's lectures when its
    /// `topic.json` decodes, and only those still in it. A folder whose metadata
    /// won't read could never be shown or deleted, so it goes.
    private nonisolated static func scanDiskContents()
        -> (topics: [Int: TopicDetail], downloaded: [Int: Set<Int>]) {
        let fm = FileManager.default
        var topics: [Int: TopicDetail] = [:]
        var downloaded: [Int: Set<Int>] = [:]
        guard let dirs = try? fm.contentsOfDirectory(at: DownloadPaths.base,
                                                     includingPropertiesForKeys: nil) else {
            return (topics, downloaded)
        }
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            guard let topicID = Int(dir.lastPathComponent) else { continue }
            guard let data = try? Data(contentsOf: DownloadPaths.topicJSON(topicID)),
                  let topic = try? JSONDecoder().decode(TopicDetail.self, from: data) else {
                try? fm.removeItem(at: dir)
                continue
            }
            topics[topicID] = topic
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let ids = Set(files.filter { $0.pathExtension == "mp3" }
                .compactMap { Int($0.deletingPathExtension().lastPathComponent) })
                .intersection(topic.lectures.map(\.id))
            if !ids.isEmpty { downloaded[topicID] = ids }
        }
        return (topics, downloaded)
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let key = DownloadKey(downloadTask.taskDescription) else { return }
        let fm = FileManager.default
        Self.lastProgress.withLock { $0[ObjectIdentifier(downloadTask)] = nil }

        // The topic was deleted while this chapter was in flight: drop the file
        // rather than bring its folder back untracked.
        guard fm.fileExists(atPath: DownloadPaths.topicJSON(key.topicID).path) else {
            try? fm.removeItem(at: location)
            Task { @MainActor in self.markFailed(key, task: downloadTask) }
            return
        }

        // The task "finished" only means the bytes arrived — a 403/404 page or an
        // HTML error is just as "finished" as a real mp3. Reject anything that
        // isn't an audio body so we never save a broken file as a valid chapter.
        if !Self.isValidAudio(response: downloadTask.response, fileAt: location) {
            let error = URLError(.badServerResponse)
            Task { @MainActor in self.markFailed(key, task: downloadTask, error: error) }
            return
        }

        let dest = DownloadPaths.lectureFile(key.topicID, key.lectureID)
        do {
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: location)
            } else {
                try fm.moveItem(at: location, to: dest)
            }
            Task { @MainActor in self.markDownloaded(key, task: downloadTask) }
        } catch {
            Task { @MainActor in self.markFailed(key, task: downloadTask, error: error) }
        }
    }

    /// True only for a whole (200) or resumed (206) response whose body looks like
    /// real audio (not an HTML error page) and is larger than a trivial threshold.
    private nonisolated static func isValidAudio(response: URLResponse?, fileAt location: URL) -> Bool {
        if let http = response as? HTTPURLResponse, ![200, 206].contains(http.statusCode) { return false }
        if let mime = response?.mimeType?.lowercased(),
           mime.contains("html") || mime.contains("xml") || mime.contains("json") {
            return false
        }
        let size = (try? location.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size > 1024
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0,
              let key = DownloadKey(downloadTask.taskDescription) else { return }
        let frac = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let taskID = ObjectIdentifier(downloadTask)
        // This fires hundreds of times a second: hop to the main actor only on a
        // 1% step, so neither the hops nor the redraws pile up.
        let due = Self.lastProgress.withLock { last in
            guard frac >= 1 || abs(frac - (last[taskID] ?? -1)) >= 0.01 else { return false }
            last[taskID] = frac
            return true
        }
        guard due else { return }
        Task { @MainActor in self.setProgress(key, task: downloadTask, frac) }
    }

    /// The fraction last sent to the main actor, per task.
    private nonisolated static let lastProgress = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: Double]())

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        Self.lastProgress.withLock { $0[ObjectIdentifier(task)] = nil }
        guard let error, let key = DownloadKey(task.taskDescription) else { return }
        let info = (error as NSError).userInfo
        let cancelled = (error as? URLError)?.code == .cancelled
        let forceQuit = info[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int
            == NSURLErrorCancelledReasonUserForceQuitApplication
        // Keep the resume blob so the download continues instead of restarting —
        // unless the listener cancelled it.
        let resume = cancelled && !forceQuit ? nil : info[NSURLSessionDownloadTaskResumeData] as? Data
        // A cancel is the listener's own doing (or the app being quit): nothing to say.
        let reported = cancelled ? nil : error
        Task { @MainActor in self.markFailed(key, task: task, resumeData: resume, error: reported) }
    }

    /// All background events for this session have been delivered — invoke the
    /// completion handler iOS gave us (must run on the main thread).
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier ?? ""
        Task { @MainActor in
            self.backgroundCompletionHandlers.removeValue(forKey: identifier)?()
        }
    }
}
