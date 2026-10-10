import Foundation

public enum LogseqRuntimeLogLevel: String, Codable, Hashable, Sendable {
    case debug
    case info
    case error
}

public enum LogseqRuntimeLogSource: String, Codable, Hashable, Sendable {
    case ui
    case core
}

public struct LogseqRuntimeLogRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: Int
    public let timestampMilliseconds: Int
    public let level: LogseqRuntimeLogLevel
    public let source: LogseqRuntimeLogSource
    public let message: String
}

public final class LogseqRuntimeLog: @unchecked Sendable {
    public static let shared = LogseqRuntimeLog()

    private let capacity: Int
    private let lock = NSLock()
    private var nextID = 0
    private var storage: [LogseqRuntimeLogRecord] = []

    public init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    public func append(
        level: LogseqRuntimeLogLevel,
        source: LogseqRuntimeLogSource,
        message: String,
        timestampMilliseconds: Int = Int(Date().timeIntervalSince1970 * 1_000)
    ) {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        storage.append(LogseqRuntimeLogRecord(
            id: nextID,
            timestampMilliseconds: timestampMilliseconds,
            level: level,
            source: source,
            message: message
        ))
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    public func records(
        source: LogseqRuntimeLogSource? = nil,
        errorsOnly: Bool = false,
        newestFirst: Bool = false
    ) -> [LogseqRuntimeLogRecord] {
        lock.lock()
        let snapshot = storage
        lock.unlock()
        let filtered = snapshot.filter { record in
            (source == nil || record.source == source)
                && (!errorsOnly || record.level == .error)
        }
        return newestFirst ? Array(filtered.reversed()) : filtered
    }

    public func exportText() -> String {
        records().map { record in
            "\(record.timestampMilliseconds) \(record.level.rawValue.uppercased()) \(record.source.rawValue) \(record.message)"
        }.joined(separator: "\n")
    }
}
