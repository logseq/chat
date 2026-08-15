package logseq.chat.model

import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class AndroidGraphSSETransportException(message: String, cause: Throwable? = null) :
    Exception(message, cause)

class AndroidGraphSSEStream internal constructor(
    private val connection: HttpURLConnection
) {
    private val input = connection.inputStream.buffered()

    suspend fun nextFrame(): String? = withContext(Dispatchers.IO) {
        val frame = ByteArrayOutputStream()
        var previous1 = -1
        var previous2 = -1
        var previous3 = -1
        while (true) {
            val byte = input.read()
            if (byte == -1) {
                if (frame.size() == 0) return@withContext null
                throw AndroidGraphSSETransportException("SSE stream ended inside a frame")
            }
            frame.write(byte)
            if (frame.size() > maximumFrameBytes) {
                throw AndroidGraphSSETransportException("SSE frame exceeds the maximum size")
            }
            val lineFeedBoundary = previous1 == '\n'.code && byte == '\n'.code
            val carriageReturnBoundary =
                previous3 == '\r'.code && previous2 == '\n'.code &&
                    previous1 == '\r'.code && byte == '\n'.code
            if (lineFeedBoundary || carriageReturnBoundary) {
                return@withContext decodeUTF8(frame.toByteArray())
            }
            previous3 = previous2
            previous2 = previous1
            previous1 = byte
        }
        null
    }

    fun close() {
        try {
            input.close()
        } catch (_: Exception) {
            // Disconnecting the connection is the authoritative cleanup operation.
        }
        connection.disconnect()
    }

    private fun decodeUTF8(bytes: ByteArray): String = try {
        StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
            .toString()
    } catch (error: Exception) {
        throw AndroidGraphSSETransportException("SSE frame is not valid UTF-8", error)
    }

    private companion object {
        const val maximumFrameBytes = 64 * 1024 * 1024
    }
}

object AndroidGraphSSETransport {
    suspend fun open(
        baseURL: String,
        graphID: String,
        appliedServerT: Int,
        accessToken: String
    ): AndroidGraphSSEStream = withContext(Dispatchers.IO) {
        val connection = (eventsURL(baseURL, graphID, appliedServerT).openConnection()
            as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 30_000
            readTimeout = 30_000
            setRequestProperty("Authorization", "Bearer $accessToken")
            setRequestProperty("Accept", "text/event-stream")
        }
        try {
            val status = connection.responseCode
            if (status !in 200..299) {
                throw AndroidGraphSSETransportException("Graph events failed with HTTP $status")
            }
            AndroidGraphSSEStream(connection)
        } catch (error: Exception) {
            connection.disconnect()
            if (error is AndroidGraphSSETransportException) throw error
            throw AndroidGraphSSETransportException("Could not open graph events", error)
        }
    }

    private fun eventsURL(baseURL: String, graphID: String, appliedServerT: Int): URL {
        var root = baseURL.trim().trimEnd('/')
        if (root.endsWith("/api")) root = root.removeSuffix("/api")
        val encodedGraphID = URLEncoder.encode(graphID, StandardCharsets.UTF_8.name())
            .replace("+", "%20")
        return try {
            URL("$root/sync/$encodedGraphID/events?since=$appliedServerT")
        } catch (error: Exception) {
            throw AndroidGraphSSETransportException("Logseq API base URL is invalid", error)
        }
    }
}
