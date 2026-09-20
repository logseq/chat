package com.logseq.chat

import logseq.chat.AndroidRuntimeLog
import logseq.chat.AndroidRuntimeLogLevel
import logseq.chat.AndroidRuntimeLogSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidRuntimeLogTest {
    @Test
    fun `bounds filters and orders runtime records like iOS`() {
        val log = AndroidRuntimeLog(capacity = 2)
        log.append(AndroidRuntimeLogLevel.INFO, AndroidRuntimeLogSource.UI, "first", 1)
        log.append(AndroidRuntimeLogLevel.ERROR, AndroidRuntimeLogSource.CORE, "second", 2)
        log.append(AndroidRuntimeLogLevel.INFO, AndroidRuntimeLogSource.CORE, "third", 3)

        assertEquals(listOf("second", "third"), log.records().map { it.message })
        assertEquals(
            listOf("second"),
            log.records(source = AndroidRuntimeLogSource.CORE, errorsOnly = true)
                .map { it.message },
        )
        assertEquals(
            listOf("third", "second"),
            log.records(source = AndroidRuntimeLogSource.CORE, newestFirst = true)
                .map { it.message },
        )
    }

    @Test
    fun `encodes the LG runtime log payload and escapes messages`() {
        val log = AndroidRuntimeLog(capacity = 2)
        log.append(
            AndroidRuntimeLogLevel.ERROR,
            AndroidRuntimeLogSource.UI,
            "Failed \"safely\"\nnext",
            0,
        )

        val encoded = log.encodedRecords(
            source = AndroidRuntimeLogSource.UI,
            errorsOnly = true,
            newestFirst = false,
        )

        assertTrue(encoded.contains("\"level\":\"ERROR\""))
        assertTrue(encoded.contains("\"source\":\"ui\""))
        assertTrue(encoded.contains("Failed \\\"safely\\\"\\nnext"))
    }
}
