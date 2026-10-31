import Foundation

/// Which per-job stems directories (`~/Library/Caches/Booth/jobs/<uuid>`) to delete. Preview
/// stems are large (five float32 tracks per job, about 3.5 GB per hour of audio).
///
/// - Directories of this session's jobs that can still use them are protected (queued and running
///   jobs, and finished ones whose Done screen can still be reached or whose Save is running), so
///   they are never removed and don't use up the slots.
/// - Of the rest, only the newest `keep` survive. At launch nothing earlier is reachable (jobs
///   aren't persisted), so launch keeps none, but spares recently modified directories that
///   may belong to a second Booth running at the same time.
public enum JobCachePolicy {
    /// Unprotected directories a prune during a session leaves.
    public static let keepCount = 10
    /// At launch: directories modified this recently may be another Booth's live job.
    public static let launchGracePeriod: TimeInterval = 60 * 60

    public struct Entry: Equatable, Sendable {
        public var url: URL
        /// The latest modification of the directory or anything directly in it.
        public var modified: Date

        public init(url: URL, modified: Date) {
            self.url = url
            self.modified = modified
        }
    }

    /// Everything but the `keep` most recently modified unprotected entries. `protected` paths
    /// are never removed and don't count toward `keep`; entries modified after `sparingAfter`
    /// are left alone too.
    public static func directoriesToRemove(
        _ entries: [Entry], keep: Int = keepCount, protected: Set<String> = [], sparingAfter cutoff: Date? = nil
    ) -> [URL] {
        let protectedPaths = Set(protected.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let candidates = entries.filter { entry in
            if protectedPaths.contains(entry.url.standardizedFileURL.path) { return false }
            if let cutoff, entry.modified > cutoff { return false }
            return true
        }
        return candidates.sorted { $0.modified > $1.modified }.dropFirst(max(0, keep)).map(\.url)
    }
}
