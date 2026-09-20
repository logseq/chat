package com.logseq.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AndroidAppEntryParserTest {
    @Test
    fun canonicalizesSupportedDeepLinks() {
        assertEquals("open-journal", AndroidAppEntryParser.deepLinkKind("logseqchat://journal"))
        assertEquals("open-capture", AndroidAppEntryParser.deepLinkKind("LOGSEQCHAT://CAPTURE"))
        assertNull(AndroidAppEntryParser.deepLinkKind("https://logseq.com"))
        assertNull(AndroidAppEntryParser.deepLinkKind("logseqchat://capture?text=hello"))
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
