package com.logseq.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AndroidAppEntryParserTest {
    @Test
    fun canonicalizesSupportedDeepLinks() {
        assertEquals("open-journal", AndroidAppEntryParser.deepLinkKind("logseq://journal"))
        assertEquals("open-capture", AndroidAppEntryParser.deepLinkKind("LOGSEQ://CAPTURE"))
        assertNull(AndroidAppEntryParser.deepLinkKind("https://logseq.com"))
        assertNull(AndroidAppEntryParser.deepLinkKind("logseq://capture?text=hello"))
    }

    @Test
    fun normalizesSharedTextAndWebLinks() {
        assertEquals(
            "[Example](https://example.com)",
            AndroidAppEntryParser.sharedBlockText(" https://example.com ", " Example "),
        )
        assertEquals(
            "Example body",
            AndroidAppEntryParser.sharedBlockText("Example body", "Example"),
        )
        assertNull(AndroidAppEntryParser.sharedBlockText(" ", "\n"))
    }
}
