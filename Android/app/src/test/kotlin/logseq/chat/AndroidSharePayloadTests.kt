package logseq.chat

import kotlin.test.Test
import kotlin.test.assertEquals

class AndroidSharePayloadTests {
    @Test
    fun preservesTextAndTitleWithoutDuplicatingTheTitle() {
        assertEquals(
            AndroidSharePayload(text = "A useful excerpt", title = "Example"),
            AndroidSharePayload.normalized(text = "A useful excerpt", title = "Example")
        )
        assertEquals(
            AndroidSharePayload(text = "Example body", title = null),
            AndroidSharePayload.normalized(text = "Example body", title = "Example")
        )
    }

    @Test
    fun ignoresWhitespaceOnlyShares() {
        assertEquals(null, AndroidSharePayload.normalized(text = "  ", title = "\n"))
    }
}
