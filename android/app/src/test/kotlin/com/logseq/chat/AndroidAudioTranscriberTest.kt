package com.logseq.chat

import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidAudioTranscriberTest {
    @Test
    fun finalSegmentsReplaceTheirPrecedingPartialResult() {
        val accumulator = AndroidTranscriptAccumulator()

        accumulator.updatePartial("  first partial ")
        accumulator.appendFinal(" first final ")
        accumulator.updatePartial(" second partial ")

        assertEquals("first final second partial", accumulator.transcript())
    }

    @Test
    fun emptyRecognitionUpdatesDoNotCreateTranscriptWhitespace() {
        val accumulator = AndroidTranscriptAccumulator()

        accumulator.updatePartial("  ")
        accumulator.appendFinal("")

        assertEquals("", accumulator.transcript())
    }
}
