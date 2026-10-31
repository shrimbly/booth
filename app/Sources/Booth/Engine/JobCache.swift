import BoothCore
import Foundation

/// The per-job stems directories under `~/Library/Caches/Booth/jobs`. Each job writes its preview
/// stems there; `JobCachePolicy` decides which ones a prune removes.
enum JobCache {
    /// Creates a job's directory (and the root) if needed.
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Prunes `root` in the background (see `prune`).
    static func pruneInBackground(
        root: URL, keep: Int = JobCachePolicy.keepCount, protecting: Set<URL> = [], sparingWithin grace: TimeInterval? = nil
    ) {
        let protected = Set(protecting.map(\.path))
        DispatchQueue.global(qos: .utility).async {
            let cutoff = grace.map { Date(timeIntervalSinceNow: -$0) }
            prune(root: root, keep: keep, protected: protected, sparingAfter: cutoff)
        }
    }

    /// Deletes the directories under `root` that `JobCachePolicy` gives up: never `protected`
    /// ones (jobs in use), nor those modified after `sparingAfter`; of the rest the newest
    /// `keep` stay.
    static func prune(root: URL, keep: Int = JobCachePolicy.keepCount, protected: Set<String>, sparingAfter cutoff: Date? = nil) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let children = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return
        }
        let entries = children.compactMap { url -> JobCachePolicy.Entry? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true else { return nil }
            return JobCachePolicy.Entry(url: url, modified: latestModification(of: url, own: values.contentModificationDate))
        }
        for doomed in JobCachePolicy.directoriesToRemove(entries, keep: keep, protected: protected, sparingAfter: cutoff) {
            remove(doomed)
        }
    }

    /// Deletes one job's directory (a job that ended without a result).
    static func removeInBackground(_ directory: URL) {
        DispatchQueue.global(qos: .utility).async { remove(directory) }
    }

    private static func remove(_ directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
            Log.info("job cache: removed \(directory.lastPathComponent)")
        } catch {
            Log.error("job cache: could not remove \(directory.path): \(error.localizedDescription)")
        }
    }

    /// A directory's own date changes only when entries come and go; a stem being written
    /// changes the file's. The latest of both says whether a job is still using it.
    private static func latestModification(of directory: URL, own: Date?) -> Date {
        var latest = own ?? .distantPast
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
        for file in files {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date > latest {
                latest = date
            }
        }
        return latest
    }
}
