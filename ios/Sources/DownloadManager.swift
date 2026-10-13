import Foundation
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
    /// Resume data from an interrupted download, so a retry continues instead of
    /// restarting from zero.
    private var resumeData: [DownloadKey: Data] = [:]
    /// Downloads that failed since the last alert about it, and whether one
    /// failed for want of space. Reported once the batch settles.
    private var failures = 0
    private var outOfSpace = false
    private var failureReport: Task<Void, Never>?
    /// Set by the app delegate when iOS relaunches us to deliver finished
    /// background transfers; called once all events are processed.
    var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        // Background session: downloads survive backgrounding / app termination and
        // are handed back via `handleEventsForBackgroundURLSession`. Capped to a few
        // connections per host so a 50-chapter topic doesn't fire 50 requests at once
        // (throttle / ban risk).
        let c = URLSessionConfiguration.background(withIdentifier: "com.personal.vuhe.downloads")
        c.httpAdditionalHeaders = ["User-Agent": DownloadManager.userAgent]
        c.httpMaximumConnectionsPerHost = 3
        // Relaunch the app to deliver finished transfers — an iOS-only concept.
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    static let userAgent = "Mozilla/5.0 (iPhone)"

    private override init() {
        super.init()
        // Downloads happen only when asked for: drop what the old "Download
        // Next Lectures" setting left behind.
        UserDefaults.standard.removeObject(forKey: "lecture.autoDownload")
        UserDefaults.standard.removeObject(forKey: "lecture.autoDownloadWiFiOnly")
        // Create the background session now, not lazily, so transfers that outlived
        // the last launch reconnect and report to us.
        _ = session
        Task {
            await loadDiskContents()
            await adoptRunningTasks()
            refreshSizes()
        }
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
    /// passes when relaunching to deliver finished transfers. Touching `session`
    /// makes sure the background session is connected so its delegate callbacks
    /// fire for the pending events.
    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        _ = session
    }

    /// Takes back the transfers still running in the background session from an
    /// earlier launch, so they show progress, block duplicates and can be
    /// cancelled. Ones for topics no longer saved (or already on disk) are dropped.
    private func adoptRunningTasks() async {
        for case let task as URLSessionDownloadTask in await session.allTasks {
            guard let key = DownloadKey(task.taskDescription) else { task.cancel(); continue }
            if activeTasks[key] === task { continue }   // queued this launch
            // Only the old fetch-ahead waited for Wi-Fi; nobody asked for those.
            guard task.allowsCellular else { task.cancel(); continue }
            guard savedTopics[key.topicID] != nil, !isDownloaded(key.topicID, key.lectureID),
                  activeTasks[key] == nil else { task.cancel(); continue }
            activeTasks[key] = task
            let expected = task.countOfBytesExpectedToReceive
            live.values[key] = expected > 0 ? Double(task.countOfBytesReceived) / Double(expected) : 0
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
    }

    /// Download a single chapter.
    func downloadLecture(topic: TopicDetail, lecture: Lecture) {
        guard ensureSaved(topic) else { return }
        guard !isDownloaded(topic.id, lecture.id) else { return }
        enqueue(topic: topic, lecture: lecture)
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
    }

    /// Remove the whole topic from downloads. A chapter playing from it carries
    /// on from the stream.
    func deleteTopic(_ topicID: Int) {
        if let topic = savedTopics[topicID] { cancelTopic(topic) }
        try? FileManager.default.removeItem(at: DownloadPaths.topicDir(topicID))
        downloaded[topicID] = nil
        savedTopics[topicID] = nil
        topicSizes[topicID] = nil
        resumeData = resumeData.filter { $0.key.topicID != topicID }
        AudioPlayer.shared.downloadsRemoved(topicID: topicID)
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
        live.values[key] = 0
        // Continue from where an interrupted download left off, if we have its
        // resume blob; otherwise start fresh.
        let task = resumeData.removeValue(forKey: key).map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: URLRequest(url: lecture.url))
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
            Alerts.shared.show("Can’t Download", message: "The topic couldn’t be saved on this iPhone.",
                               [AlertButton(title: "OK") {}])
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

    /// True if `taskID` is the chapter's current task — callbacks from a replaced
    /// or cancelled one arrive late and mustn't touch the new task's state.
    private func isCurrent(_ key: DownloadKey, _ taskID: Int) -> Bool {
        activeTasks[key]?.taskIdentifier == taskID
    }

    fileprivate func markDownloaded(_ key: DownloadKey, taskID: Int) {
        // The file is gone if the topic was deleted while the move hopped over here.
        guard FileManager.default.fileExists(atPath: DownloadPaths.lectureFile(key.topicID, key.lectureID).path)
        else { return }
        downloaded[key.topicID, default: []].insert(key.lectureID)
        if activeTasks[key] == nil || isCurrent(key, taskID) {
            live.values[key] = nil
            activeTasks[key] = nil
        }
        scheduleSizeRefresh(key.topicID)
    }

    /// `error` is why, when it's worth telling the listener (not a cancel).
    fileprivate func markFailed(_ key: DownloadKey, taskID: Int, resumeData: Data? = nil, error: Error? = nil) {
        // Resume data from a transfer cut off before this launch adopted it
        // (the app was force-quit) is still worth keeping for a retry.
        if let resumeData, activeTasks[key] == nil || isCurrent(key, taskID) {
            self.resumeData[key] = resumeData
        }
        guard isCurrent(key, taskID) else { return }
        live.values[key] = nil
        activeTasks[key] = nil
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
                ? "There isn’t enough space on this iPhone. Free some up and try again."
                : "\(formatCount(failures, "lecture", "lectures")) couldn’t be downloaded. Try again later."
            failures = 0
            outOfSpace = false
            Alerts.shared.show("Download Failed", message: message, [AlertButton(title: "OK") {}])
        }
    }

    fileprivate func setProgress(_ key: DownloadKey, taskID: Int, _ value: Double) {
        guard isCurrent(key, taskID) else { return }
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
        let taskID = downloadTask.taskIdentifier
        Self.lastProgress.withLock { $0[taskID] = nil }

        // The topic was deleted while this chapter was in flight: drop the file
        // rather than bring its folder back untracked.
        guard fm.fileExists(atPath: DownloadPaths.topicJSON(key.topicID).path) else {
            try? fm.removeItem(at: location)
            Task { @MainActor in self.markFailed(key, taskID: taskID) }
            return
        }

        // The task "finished" only means the bytes arrived — a 403/404 page or an
        // HTML error is just as "finished" as a real mp3. Reject anything that
        // isn't an audio body so we never save a broken file as a valid chapter.
        if !Self.isValidAudio(response: downloadTask.response, fileAt: location) {
            let error = URLError(.badServerResponse)
            Task { @MainActor in self.markFailed(key, taskID: taskID, error: error) }
            return
        }

        let dest = DownloadPaths.lectureFile(key.topicID, key.lectureID)
        do {
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: location)
            } else {
                try fm.moveItem(at: location, to: dest)
            }
            Task { @MainActor in self.markDownloaded(key, taskID: taskID) }
        } catch {
            Task { @MainActor in self.markFailed(key, taskID: taskID, error: error) }
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
        let taskID = downloadTask.taskIdentifier
        // This fires hundreds of times a second: hop to the main actor only on a
        // 1% step, so neither the hops nor the redraws pile up.
        let due = Self.lastProgress.withLock { last in
            guard frac >= 1 || abs(frac - (last[taskID] ?? -1)) >= 0.01 else { return false }
            last[taskID] = frac
            return true
        }
        guard due else { return }
        Task { @MainActor in self.setProgress(key, taskID: taskID, frac) }
    }

    /// The fraction last sent to the main actor, per task.
    private nonisolated static let lastProgress = OSAllocatedUnfairLock(initialState: [Int: Double]())

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        Self.lastProgress.withLock { $0[task.taskIdentifier] = nil }
        guard let error, let key = DownloadKey(task.taskDescription) else { return }
        // Keep the resume blob (if any) so a retry continues instead of restarting.
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let taskID = task.taskIdentifier
        // A cancel is the listener's own doing (or the app being quit): nothing to say.
        let reported = (error as? URLError)?.code == .cancelled ? nil : error
        Task { @MainActor in self.markFailed(key, taskID: taskID, resumeData: resume, error: reported) }
    }

    /// All background events for this session have been delivered — invoke the
    /// completion handler iOS gave us (must run on the main thread).
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }
}

private extension URLSessionTask {
    /// False for a Wi-Fi-only request (one that waits for an unmetered network),
    /// which only the removed fetch-ahead made.
    var allowsCellular: Bool { originalRequest?.allowsCellularAccess ?? true }
}
