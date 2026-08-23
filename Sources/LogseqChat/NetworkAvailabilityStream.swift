import Foundation

#if !SKIP
import Network
#endif

enum NetworkAvailabilityStream {
    static func values() -> AsyncStream<Bool> {
        #if SKIP
        return AsyncStream { continuation in
            continuation.yield(true)
            continuation.finish()
        }
        #else
        let monitor = NWPathMonitor()
        return AsyncStream { continuation in
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "com.logseq.chat.network-availability"))
        }
        #endif
    }
}
