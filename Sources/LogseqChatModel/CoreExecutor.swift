import Foundation

#if !SKIP
enum LogseqChatCorePriority: Int, Sendable {
    case maintenance
    case normal
    case interaction
}

final class LogseqChatCoreExecutor: @unchecked Sendable {
    static let shared = LogseqChatCoreExecutor()

    private struct Job: Sendable {
        let callCore: @Sendable (String) -> String
        let requestJSON: String
        let priority: LogseqChatCorePriority
        let continuation: CheckedContinuation<String, Never>
    }

    private final class State: @unchecked Sendable {
        private let condition = NSCondition()
        private var jobs: [Job] = []

        func enqueue(_ job: Job) {
            condition.lock()
            jobs.append(job)
            condition.signal()
            condition.unlock()
        }

        func next() -> Job {
            condition.lock()
            while jobs.isEmpty {
                condition.wait()
            }
            var selectedIndex = jobs.startIndex
            for index in jobs.indices where jobs[index].priority.rawValue > jobs[selectedIndex].priority.rawValue {
                selectedIndex = index
            }
            let job = jobs.remove(at: selectedIndex)
            condition.unlock()
            return job
        }
    }

    private let state: State
    private let thread: Thread

    private init() {
        let state = State()
        self.state = state
        self.thread = Thread {
            Thread.current.name = "LogseqChatCore"
            LogseqChatCore.shared.initialize()
            while true {
                let job = state.next()
                job.continuation.resume(returning: job.callCore(job.requestJSON))
            }
        }
        thread.name = "LogseqChatCore"
        thread.start()
    }

    func call(
        _ callCore: @escaping @Sendable (String) -> String,
        requestJSON: String,
        priority: LogseqChatCorePriority = .normal
    ) async -> String {
        await withCheckedContinuation { continuation in
            state.enqueue(Job(
                callCore: callCore,
                requestJSON: requestJSON,
                priority: priority,
                continuation: continuation
            ))
        }
    }
}
#endif
