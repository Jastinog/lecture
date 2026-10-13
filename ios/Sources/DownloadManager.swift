import Foundation

/// Paths for offline storage: Application Support/Downloads/<bookId>/...
enum DownloadPaths {
    static var base: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
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

/// Live per-chapter download progress. See `DownloadManager.live`.
@MainActor
final class DownloadProgress: ObservableObject {
    @Published fileprivate(set) var values: [Int: Double] = [:]
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    /// topicID -> set of downloaded trackIDs.
    @Published private(set) var downloaded: [Int: Set<Int>] = [:]
    /// lectureID -> active download progress (0…1). Published on its own object so
    /// the 1%-step updates (constant while a topic downloads) redraw only the
    /// download indicators, not every screen that observes the manager.
    let live = DownloadProgress()
    var progress: [Int: Double] { live.values }
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

    private var activeTasks: [Int: URLSessionDownloadTask] = [:]   // lectureID -> task
    /// Resume data from an interrupted download, so a retry continues instead of
    /// restarting from zero. lectureID -> resume blob.
    private var resumeData: [Int: Data] = [:]
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
            guard let (topicID, lectureID) = Self.parse(task.taskDescription) else { task.cancel(); continue }
            if activeTasks[lectureID] === task { continue }   // queued this launch
            // Only the old fetch-ahead waited for Wi-Fi; nobody asked for those.
            guard task.allowsCellular else { task.cancel(); continue }
            guard savedTopics[topicID] != nil, !isDownloaded(topicID, lectureID),
                  activeTasks[lectureID] == nil else { task.cancel(); continue }
            activeTasks[lectureID] = task
            let expected = task.countOfBytesExpectedToReceive
            live.values[lectureID] = expected > 0 ? Double(task.countOfBytesReceived) / Double(expected) : 0
        }
    }

    // MARK: - State queries

    func isDownloaded(_ topicID: Int, _ lectureID: Int) -> Bool {
        downloaded[topicID]?.contains(lectureID) ?? false
    }
    func downloadedCount(_ topicID: Int) -> Int { downloaded[topicID]?.count ?? 0 }
    func isTopicDownloading(_ topic: TopicDetail) -> Bool {
        topic.lectures.contains { activeTasks[$0.id] != nil }
    }
    func isFullyDownloaded(_ topic: TopicDetail) -> Bool {
        downloadedCount(topic.id) == topic.lectures.count && topic.lectures.count > 0
    }
    /// How much of the topic is on the phone, counting the part of each lecture
    /// still coming in.
    func topicFraction(_ topic: TopicDetail) -> Double {
        guard !topic.lectures.isEmpty else { return 0 }
        let partial = topic.lectures.reduce(0.0) { $0 + (live.values[$1.id] ?? 0) }
        return (Double(downloadedCount(topic.id)) + partial) / Double(topic.lectures.count)
    }

    /// Local chapter file, if downloaded.
    func localLectureURL(topicID: Int, lectureID: Int) -> URL? {
        guard isDownloaded(topicID, lectureID) else { return nil }
        let f = DownloadPaths.lectureFile(topicID, lectureID)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
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
        for lecture in topic.lectures {
            activeTasks[lecture.id]?.cancel()
            activeTasks[lecture.id] = nil
            live.values[lecture.id] = nil
        }
    }

    /// Remove the whole topic from downloads.
    func deleteTopic(_ topicID: Int) {
        if let topic = savedTopics[topicID] { cancelTopic(topic) }
        try? FileManager.default.removeItem(at: DownloadPaths.topicDir(topicID))
        downloaded[topicID] = nil
        savedTopics[topicID] = nil
        topicSizes[topicID] = nil
    }

    // MARK: - Internals

    private func enqueue(topic: TopicDetail, lecture: Lecture) {
        guard activeTasks[lecture.id] == nil else { return }   // already on its way
        // Only download over https (the URL comes from inline page JS).
        guard lecture.url.scheme == "https" else { return }
        live.values[lecture.id] = 0
        // Continue from where an interrupted download left off, if we have its
        // resume blob; otherwise start fresh.
        let task = resumeData.removeValue(forKey: lecture.id).map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: URLRequest(url: lecture.url))
        task.taskDescription = "\(topic.id):\(lecture.id)"
        activeTasks[lecture.id] = task
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
                    try? data.write(to: coverFile)
                }
            }
        }
        return true
    }

    /// True if `taskID` is the chapter's current task — callbacks from a replaced
    /// or cancelled one arrive late and mustn't touch the new task's state.
    private func isCurrent(_ lectureID: Int, _ taskID: Int) -> Bool {
        activeTasks[lectureID]?.taskIdentifier == taskID
    }

    fileprivate func markDownloaded(topicID: Int, lectureID: Int, taskID: Int) {
        // The file is gone if the topic was deleted while the move hopped over here.
        guard FileManager.default.fileExists(atPath: DownloadPaths.lectureFile(topicID, lectureID).path) else { return }
        downloaded[topicID, default: []].insert(lectureID)
        if activeTasks[lectureID] == nil || isCurrent(lectureID, taskID) {
            live.values[lectureID] = nil
            activeTasks[lectureID] = nil
        }
        scheduleSizeRefresh(topicID)
    }

    fileprivate func markFailed(lectureID: Int, taskID: Int, resumeData: Data? = nil) {
        guard isCurrent(lectureID, taskID) else { return }
        live.values[lectureID] = nil
        activeTasks[lectureID] = nil
        if let resumeData { self.resumeData[lectureID] = resumeData }
    }

    fileprivate func setProgress(lectureID: Int, taskID: Int, _ value: Double) {
        guard isCurrent(lectureID, taskID) else { return }
        // `didWriteData` fires hundreds of times/sec; only publish on a ≥1% change
        // (or completion) so observing views don't redraw on every packet.
        let last = live.values[lectureID] ?? -1
        guard value >= 1.0 || abs(value - last) >= 0.01 else { return }
        live.values[lectureID] = value
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
    /// `topic.json` decodes — orphan lecture folders without metadata are skipped.
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
                  let topic = try? JSONDecoder().decode(TopicDetail.self, from: data) else { continue }
            topics[topicID] = topic
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let ids = files.filter { $0.pathExtension == "mp3" }
                .compactMap { Int($0.deletingPathExtension().lastPathComponent) }
            if !ids.isEmpty { downloaded[topicID] = Set(ids) }
        }
        return (topics, downloaded)
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let (topicID, lectureID) = Self.parse(downloadTask.taskDescription) else { return }
        let fm = FileManager.default
        let taskID = downloadTask.taskIdentifier

        // The topic was deleted while this chapter was in flight: drop the file
        // rather than bring its folder back untracked.
        guard fm.fileExists(atPath: DownloadPaths.topicJSON(topicID).path) else {
            try? fm.removeItem(at: location)
            Task { @MainActor in self.markFailed(lectureID: lectureID, taskID: taskID) }
            return
        }

        // The task "finished" only means the bytes arrived — a 403/404 page or an
        // HTML error is just as "finished" as a real mp3. Reject anything that
        // isn't a 200 audio body so we never save a broken file as a valid chapter.
        if !Self.isValidAudio(response: downloadTask.response, fileAt: location) {
            Task { @MainActor in self.markFailed(lectureID: lectureID, taskID: taskID) }
            return
        }

        let dest = DownloadPaths.lectureFile(topicID, lectureID)
        do {
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: location)
            } else {
                try fm.moveItem(at: location, to: dest)
            }
            Task { @MainActor in self.markDownloaded(topicID: topicID, lectureID: lectureID, taskID: taskID) }
        } catch {
            Task { @MainActor in self.markFailed(lectureID: lectureID, taskID: taskID) }
        }
    }

    /// True only for a 200 response whose body looks like real audio (not an HTML
    /// error page) and is larger than a trivial threshold.
    private nonisolated static func isValidAudio(response: URLResponse?, fileAt location: URL) -> Bool {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return false }
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
              let (_, lectureID) = Self.parse(downloadTask.taskDescription) else { return }
        let frac = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let taskID = downloadTask.taskIdentifier
        Task { @MainActor in self.setProgress(lectureID: lectureID, taskID: taskID, frac) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error, let (_, lectureID) = Self.parse(task.taskDescription) else { return }
        // Keep the resume blob (if any) so a retry continues instead of restarting.
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let taskID = task.taskIdentifier
        Task { @MainActor in self.markFailed(lectureID: lectureID, taskID: taskID, resumeData: resume) }
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

    private nonisolated static func parse(_ desc: String?) -> (Int, Int)? {
        guard let parts = desc?.split(separator: ":"), parts.count == 2,
              let b = Int(parts[0]), let t = Int(parts[1]) else { return nil }
        return (b, t)
    }
}

private extension URLSessionTask {
    /// False for a Wi-Fi-only request (one that waits for an unmetered network),
    /// which only the removed fetch-ahead made.
    var allowsCellular: Bool { originalRequest?.allowsCellularAccess ?? true }
}
