package logseq.chat

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class AndroidAppEntryPointsTests {
    @Test
    fun journalAndCaptureEntryPointsUseCanonicalDeepLinks() {
        assertEquals(
            "logseqchat://journal",
            AndroidAppEntryPoints.canonicalDeepLink("logseqchat://journal")
        )
        assertEquals(
            "logseqchat://capture",
            AndroidAppEntryPoints.canonicalDeepLink("LOGSEQCHAT://CAPTURE")
        )
    }

    @Test
    fun unsupportedOrPopulatedEntryPointsAreNotLauncherActions() {
        assertNull(AndroidAppEntryPoints.canonicalDeepLink("https://logseq.com"))
        assertNull(AndroidAppEntryPoints.canonicalDeepLink("logseqchat://capture?text=hello"))
        assertNull(AndroidAppEntryPoints.canonicalDeepLink(null))
    }
}
