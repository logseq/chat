package logseq.chat.model

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidCoreExecutorTests {
    @Test
    fun serializesCallsAcrossCoroutines() = runBlocking {
        val activeCalls = AtomicInteger(0)
        val maximumActiveCalls = AtomicInteger(0)
        val firstStarted = CountDownLatch(1)
        val secondAttempted = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)

        val first = async(Dispatchers.Default) {
            AndroidCoreExecutor.call("first") {
                val active = activeCalls.incrementAndGet()
                maximumActiveCalls.updateAndGet { current -> maxOf(current, active) }
                firstStarted.countDown()
                assertTrue(releaseFirst.await(2, TimeUnit.SECONDS))
                activeCalls.decrementAndGet()
                "first-result"
            }
        }
        assertTrue(firstStarted.await(2, TimeUnit.SECONDS))

        val second = async(Dispatchers.Default) {
            secondAttempted.countDown()
            AndroidCoreExecutor.call("second") {
                val active = activeCalls.incrementAndGet()
                maximumActiveCalls.updateAndGet { current -> maxOf(current, active) }
                activeCalls.decrementAndGet()
                "second-result"
            }
        }

        assertTrue(secondAttempted.await(2, TimeUnit.SECONDS))
        Thread.sleep(50)
        assertEquals(1, maximumActiveCalls.get())
        releaseFirst.countDown()
        assertEquals("first-result", first.await())
        assertEquals("second-result", second.await())
        assertEquals(1, maximumActiveCalls.get())
    }

    @Test
    fun continuesAfterACallThrows() = runBlocking {
        try {
            AndroidCoreExecutor.call("failing") {
                error("expected failure")
            }
        } catch (_: IllegalStateException) {
        }

        val result = AndroidCoreExecutor.call("following") { "success" }
        assertEquals("success", result)
    }
}
