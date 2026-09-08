import Foundation

import Network

enum NetworkAvailabilityStream {
    static func values() -> AsyncStream<Bool> {
        let monitor = NWPathMonitor()
        return AsyncStream { continuation in
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "com.logseq.chat.network-availability"))
        }
    }
}
