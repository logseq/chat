package logseq.chat.model

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

object AndroidGraphSnapshotTransport {
    suspend fun downloadSnapshot(
        baseURL: String,
        graphID: String,
        accessToken: String,
        workingDirectory: String,
        schemaVersion: String
    ): LogseqGraphSnapshotArtifact = withContext(Dispatchers.IO) {
        val artifact = AndroidGraphSnapshotDownloader().downloadSnapshot(
            baseURL = baseURL,
            graphID = graphID,
            accessToken = accessToken,
            workingDirectory = workingDirectory,
            schemaVersion = schemaVersion
        )
        LogseqGraphSnapshotArtifact(
            metadataBody = artifact.metadataBody,
            filePath = artifact.filePath
        )
    }
}
