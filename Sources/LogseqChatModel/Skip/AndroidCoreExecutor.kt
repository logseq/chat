package logseq.chat.model

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

object AndroidCoreExecutor {
    private val mutex = Mutex()

    suspend fun call(requestJSON: String, callCore: (String) -> String): String =
        mutex.withLock {
            withContext(Dispatchers.IO) {
                callCore(requestJSON)
            }
        }
}
