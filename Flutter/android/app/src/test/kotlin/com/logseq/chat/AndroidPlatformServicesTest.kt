package com.logseq.chat

import java.io.File
import logseq.chat.resolveAndroidFile
import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidPlatformServicesTest {
    @Test
    fun `relative assets resolve against the app files directory`() {
        assertEquals(
            File("/data/user/0/com.logseq.chat/files/Assets/photo.png"),
            resolveAppFile(
                File("/data/user/0/com.logseq.chat/files"),
                "Assets/photo.png",
            ),
        )
    }

    @Test
    fun `absolute asset paths remain unchanged`() {
        assertEquals(
            File("/data/user/0/com.logseq.chat/cache/shared.png"),
            resolveAppFile(
                File("/data/user/0/com.logseq.chat/files"),
                "/data/user/0/com.logseq.chat/cache/shared.png",
            ),
        )
    }

    @Test
    fun `shared Android paths resolve relative uploads against app storage`() {
        assertEquals(
            File("/data/user/0/com.logseq.chat/files/Assets/upload.png"),
            resolveAndroidFile(
                File("/data/user/0/com.logseq.chat/files"),
                "Assets/upload.png",
            ),
        )
    }

    @Test
    fun `blank base URL falls back to the local backend`() {
        assertEquals(DEFAULT_BASE_URL, normalizedBaseUrl(""))
        assertEquals(DEFAULT_BASE_URL, normalizedBaseUrl("   "))
    }

    @Test
    fun `configured base URL is trimmed and preserved`() {
        assertEquals(
            "https://sync.example.com",
            normalizedBaseUrl("  https://sync.example.com  "),
        )
    }

    @Test
    fun `stored session inspection does not require token decryption`() {
        assertEquals(false, hasStoredToken(null))
        assertEquals(false, hasStoredToken(""))
        assertEquals(false, hasStoredToken("   "))
        assertEquals(true, hasStoredToken("encrypted-token-envelope"))
    }

    @Test
    fun `void platform results are encoded as Flutter null`() {
        assertEquals(null, flutterEncodableResult(Unit))
        assertEquals("value", flutterEncodableResult("value"))
    }

    @Test
    fun `asset titles cannot escape the Assets directory`() {
        assertEquals("photo.png", safeAssetTitle("../../photo.png"))
        assertEquals("Attachment", safeAssetTitle(""))
        assertEquals("Attachment", safeAssetTitle(null))
    }
}
