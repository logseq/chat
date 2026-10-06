package com.logseq.chat

import logseq.chat.AndroidGraphSnapshotDownloader
import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidGraphSnapshotDownloaderTest {
    @Test
    fun `snapshot endpoints remove api suffix and encode graph ids`() {
        val downloader = AndroidGraphSnapshotDownloader()

        assertEquals(
            "https://sync.example.com/sync/graph%20id/snapshot/download",
            downloader.snapshotMetadataUrl("https://sync.example.com/api/", "graph id").toString(),
        )
        assertEquals(
            "https://sync.example.com/sync/graph%20id/pull",
            downloader.snapshotCursorUrl("https://sync.example.com/api/", "graph id").toString(),
        )
    }
}
