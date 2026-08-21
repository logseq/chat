package logseq.chat

import kotlin.test.Test
import kotlin.test.assertEquals

class AndroidTranscriptAccumulatorTests {
    @Test
    fun finalSegmentsAreJoinedAndPartialTextIsOnlyAFallback() {
        val accumulator = AndroidTranscriptAccumulator()

        accumulator.updatePartial("Hello wor")
        assertEquals("Hello wor", accumulator.transcript())

        accumulator.appendFinal("Hello world")
        accumulator.updatePartial("Second")
        assertEquals("Hello world Second", accumulator.transcript())

        accumulator.appendFinal("Second sentence")
        assertEquals("Hello world Second sentence", accumulator.transcript())
    }

    @Test
    fun blankRecognitionUpdatesAreIgnored() {
        val accumulator = AndroidTranscriptAccumulator()

        accumulator.updatePartial("  ")
        accumulator.appendFinal("\n")

        assertEquals("", accumulator.transcript())
    }
}
