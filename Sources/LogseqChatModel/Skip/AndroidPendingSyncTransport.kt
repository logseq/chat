package logseq.chat.model

import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runInterruptible

object AndroidPendingSyncTransport {
    suspend fun send(request: LogseqPendingSyncRequest): LogseqPendingSyncResult =
        runInterruptible(Dispatchers.IO) {
            val connection = try {
                (URL(request.url).openConnection() as HttpURLConnection).apply {
                    requestMethod = request.method
                    connectTimeout = 30_000
                    readTimeout = 30_000
                    setRequestProperty("Authorization", "Bearer ${request.token}")
                    setRequestProperty("Accept", "application/json")
                    setRequestProperty("Content-Type", request.contentType)
                    doInput = true
                }
            } catch (error: Exception) {
                return@runInterruptible LogseqPendingSyncResult(null, null, error.message ?: error.toString())
            }

            try {
                val filePath = request.filePath
                val body = request.body
                if (filePath != null || body != null) {
                    connection.doOutput = true
                    connection.outputStream.buffered().use { output ->
                        if (filePath != null) {
                            File(filePath).inputStream().buffered().use { input -> input.copyTo(output) }
                        } else if (body != null) {
                            output.write(body.toByteArray(StandardCharsets.UTF_8))
                        }
                    }
                }
                val status = connection.responseCode
                val input = if (status in 200..299) connection.inputStream else connection.errorStream
                val responseBody = input?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() } ?: ""
                LogseqPendingSyncResult(status, responseBody, null)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                LogseqPendingSyncResult(null, null, error.message ?: error.toString())
            } finally {
                connection.disconnect()
            }
        }
}
