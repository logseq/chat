package logseq.chat.model

import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.util.zip.GZIPInputStream
import org.json.JSONObject

data class AndroidDownloadedSnapshot(
    val metadataBody: String,
    val filePath: String
)

class AndroidGraphSnapshotTransportException(message: String, cause: Throwable? = null) :
    Exception(message, cause)

class AndroidGraphSnapshotDownloader {
    fun downloadSnapshot(
        baseURL: String,
        graphID: String,
        accessToken: String,
        workingDirectory: String
    ): AndroidDownloadedSnapshot {
        val metadataURL = snapshotMetadataURL(baseURL, graphID)
        val metadataBody = readMetadata(metadataURL, accessToken)
        val metadata = try {
            JSONObject(metadataBody)
        } catch (error: Exception) {
            throw AndroidGraphSnapshotTransportException("Snapshot metadata is not valid JSON", error)
        }
        if (!metadata.optBoolean("ok", false)) {
            throw AndroidGraphSnapshotTransportException("Snapshot metadata did not report success")
        }
        val snapshotURL = try {
            URL(metadataURL, metadata.getString("url"))
        } catch (error: Exception) {
            throw AndroidGraphSnapshotTransportException("Snapshot metadata URL is invalid", error)
        }
        val contentEncoding = metadata.optString("content-encoding", "identity")
            .trim()
            .lowercase()
        if (contentEncoding != "identity" && contentEncoding != "gzip") {
            throw AndroidGraphSnapshotTransportException(
                "Unsupported snapshot content encoding: $contentEncoding"
            )
        }

        val directory = File(workingDirectory)
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw AndroidGraphSnapshotTransportException(
                "Could not create snapshot directory: ${directory.absolutePath}"
            )
        }
        val download = File.createTempFile("logseq-graph-", ".download", directory)
        var decoded: File? = null
        try {
            downloadSnapshotFile(snapshotURL, accessToken, download)
            val snapshot = if (contentEncoding == "gzip") {
                File.createTempFile("logseq-graph-", ".snapshot", directory).also { output ->
                    decoded = output
                    GZIPInputStream(download.inputStream().buffered()).use { input ->
                        output.outputStream().buffered().use { destination -> input.copyTo(destination) }
                    }
                    if (!download.delete()) {
                        throw AndroidGraphSnapshotTransportException(
                            "Could not remove compressed snapshot artifact"
                        )
                    }
                }
            } else {
                download
            }
            return AndroidDownloadedSnapshot(metadataBody, snapshot.absolutePath)
        } catch (error: Exception) {
            download.delete()
            decoded?.delete()
            if (error is AndroidGraphSnapshotTransportException) throw error
            throw AndroidGraphSnapshotTransportException("Could not download graph snapshot", error)
        }
    }

    private fun snapshotMetadataURL(baseURL: String, graphID: String): URL {
        var root = baseURL.trim().trimEnd('/')
        if (root.endsWith("/api")) root = root.removeSuffix("/api")
        val encodedGraphID = URLEncoder.encode(graphID, StandardCharsets.UTF_8.name())
            .replace("+", "%20")
        return try {
            URL("$root/sync/$encodedGraphID/snapshot/download")
        } catch (error: Exception) {
            throw AndroidGraphSnapshotTransportException("Logseq API base URL is invalid", error)
        }
    }

    private fun readMetadata(url: URL, accessToken: String): String {
        val connection = open(url, accessToken)
        try {
            requireSuccess(connection, "Snapshot metadata")
            return connection.inputStream.bufferedReader(StandardCharsets.UTF_8).use { it.readText() }
        } finally {
            connection.disconnect()
        }
    }

    private fun downloadSnapshotFile(url: URL, accessToken: String, destination: File) {
        val connection = open(url, accessToken)
        try {
            requireSuccess(connection, "Snapshot download")
            connection.inputStream.buffered().use { input ->
                destination.outputStream().buffered().use { output -> input.copyTo(output) }
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun open(url: URL, accessToken: String): HttpURLConnection =
        (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 30_000
            readTimeout = 120_000
            setRequestProperty("Authorization", "Bearer $accessToken")
        }

    private fun requireSuccess(connection: HttpURLConnection, operation: String) {
        val status = connection.responseCode
        if (status !in 200..299) {
            throw AndroidGraphSnapshotTransportException("$operation failed with HTTP $status")
        }
    }
}
