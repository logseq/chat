package logseq.chat.model

import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runInterruptible
import org.json.JSONObject

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
                    request.headers.forEach { (name, value) ->
                        setRequestProperty(name, value)
                    }
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
                if (filePath != null && isDuplicateAsset(status, responseBody)) {
                    val existingAsset = existingAssetBody(request.url, request.token)
                    if (existingAsset != null) {
                        return@runInterruptible LogseqPendingSyncResult(200, existingAsset, null)
                    }
                }
                LogseqPendingSyncResult(status, responseBody, null)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                LogseqPendingSyncResult(null, null, error.message ?: error.toString())
            } finally {
                connection.disconnect()
            }
        }

    private fun isDuplicateAsset(status: Int, body: String): Boolean =
        status == 409 && runCatching {
            JSONObject(body).optString("error") == "asset checksum already exists"
        }.getOrDefault(false)

    private fun existingAssetBody(uploadURL: String, token: String): String? {
        val checksum = uploadURL.substringAfter('?', "")
            .split('&')
            .mapNotNull { item ->
                val parts = item.split('=', limit = 2)
                if (parts.size == 2 && parts[0] == "checksum") {
                    URLDecoder.decode(parts[1], StandardCharsets.UTF_8)
                } else null
            }
            .firstOrNull()
            ?: return null
        val collectionURL = uploadURL.substringBefore('?')
        var cursor: String? = null
        do {
            val cursorQuery = cursor?.let {
                "&cursor=" + URLEncoder.encode(it, StandardCharsets.UTF_8)
            }.orEmpty()
            val connection = (URL("$collectionURL?limit=100$cursorQuery").openConnection()
                as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 30_000
                readTimeout = 30_000
                setRequestProperty("Authorization", "Bearer $token")
                setRequestProperty("Accept", "application/json")
            }
            try {
                val status = connection.responseCode
                if (status !in 200..299) return null
                val body = connection.inputStream.bufferedReader(StandardCharsets.UTF_8)
                    .use { it.readText() }
                val json = JSONObject(body)
                val assets = json.optJSONArray("assets") ?: return null
                for (index in 0 until assets.length()) {
                    val asset = assets.optJSONObject(index) ?: continue
                    if (asset.optString("checksum") == checksum) return asset.toString()
                }
                cursor = json.optString("next-cursor").takeIf { it.isNotBlank() }
            } finally {
                connection.disconnect()
            }
        } while (cursor != null)
        return null
    }
}
