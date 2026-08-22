package logseq.chat.model

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.GZIPOutputStream
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class AndroidGraphSnapshotTransportTests {
    private val temporaryDirectories = mutableListOf<File>()
    private val servers = mutableListOf<HttpServer>()

    @AfterTest
    fun tearDown() {
        servers.forEach { it.stop(0) }
        temporaryDirectories.forEach { it.deleteRecursively() }
    }

    @Test
    fun downloadsAndDecodesGzipSnapshotWithBearerAuthorization() {
        val metadataAuthorization = AtomicReference<String>()
        val metadataPath = AtomicReference<String>()
        val snapshotAuthorization = AtomicReference<String>()
        val snapshot = "snapshot-transit-data".toByteArray()
        val server = server(
            metadata = { exchange, baseURL ->
                metadataAuthorization.set(exchange.requestHeaders.getFirst("Authorization"))
                metadataPath.set(exchange.requestURI.rawPath)
                val body = """{"ok":true,"url":"$baseURL/file","t":42,"schema-version":"65.33","row-count":1,"content-encoding":"gzip"}"""
                respond(exchange, 200, body.toByteArray())
            },
            snapshot = { exchange ->
                snapshotAuthorization.set(exchange.requestHeaders.getFirst("Authorization"))
                respond(
                    exchange,
                    200,
                    gzip(snapshot),
                    headers = mapOf("x-snapshot-row-count" to "1")
                )
            }
        )
        val directory = temporaryDirectory()

        val artifact = AndroidGraphSnapshotDownloader().downloadSnapshot(
            baseURL = server.baseURL,
            graphID = "graph id",
            accessToken = "access-token",
            workingDirectory = directory.absolutePath
        )

        assertEquals("Bearer access-token", metadataAuthorization.get())
        assertEquals("/sync/graph%20id/snapshot/download", metadataPath.get())
        assertEquals("Bearer access-token", snapshotAuthorization.get())
        assertEquals("snapshot-transit-data", File(artifact.filePath).readText())
        assertTrue(artifact.metadataBody.contains("\"t\":42"))
        assertTrue(artifact.metadataBody.contains("\"schema-version\":\"65.33\""))
        assertEquals(1, directory.listFiles()?.size)
    }

    @Test
    fun keepsIdentityEncodedSnapshotWithoutDecompression() {
        val server = server(
            metadata = { exchange, _ ->
                val body = """{"ok":true,"url":"/file","t":7,"schema-version":"65.33","row-count":1,"content-encoding":"identity"}"""
                respond(exchange, 200, body.toByteArray())
            },
            snapshot = { exchange ->
                respond(
                    exchange,
                    200,
                    "plain-snapshot".toByteArray(),
                    headers = mapOf("x-snapshot-row-count" to "1")
                )
            }
        )
        val directory = temporaryDirectory()

        val artifact = AndroidGraphSnapshotDownloader().downloadSnapshot(
            baseURL = "${server.baseURL}/api",
            graphID = "graph",
            accessToken = "token",
            workingDirectory = directory.absolutePath
        )

        assertEquals("plain-snapshot", File(artifact.filePath).readText())
    }

    @Test
    fun rejectsMetadataFailureWithoutLeavingPartialFiles() {
        val server = server(
            metadata = { exchange, _ -> respond(exchange, 403, "forbidden".toByteArray()) },
            snapshot = { exchange -> respond(exchange, 500, ByteArray(0)) }
        )
        val directory = temporaryDirectory()

        assertFailsWith<AndroidGraphSnapshotTransportException> {
            AndroidGraphSnapshotDownloader().downloadSnapshot(
                baseURL = server.baseURL,
                graphID = "graph",
                accessToken = "token",
                workingDirectory = directory.absolutePath
            )
        }
        assertTrue(directory.listFiles().isNullOrEmpty())
    }

    @Test
    fun removesPartialDownloadWhenSnapshotRequestFails() {
        val server = server(
            metadata = { exchange, baseURL ->
                val body = """{"ok":true,"url":"$baseURL/file","t":9,"schema-version":"65.33","row-count":1,"content-encoding":"gzip"}"""
                respond(exchange, 200, body.toByteArray())
            },
            snapshot = { exchange -> respond(exchange, 500, "failed".toByteArray()) }
        )
        val directory = temporaryDirectory()

        assertFailsWith<AndroidGraphSnapshotTransportException> {
            AndroidGraphSnapshotDownloader().downloadSnapshot(
                baseURL = server.baseURL,
                graphID = "graph",
                accessToken = "token",
                workingDirectory = directory.absolutePath
            )
        }
        assertTrue(directory.listFiles().isNullOrEmpty())
    }

    private fun temporaryDirectory(): File =
        Files.createTempDirectory("logseq-chat-snapshot-test").toFile().also(temporaryDirectories::add)

    private fun server(
        metadata: (HttpExchange, String) -> Unit,
        snapshot: (HttpExchange) -> Unit
    ): TestServer {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val baseURL = "http://127.0.0.1:${server.address.port}"
        server.createContext("/") { exchange ->
            when {
                exchange.requestURI.path == "/file" -> snapshot(exchange)
                exchange.requestURI.path.endsWith("/pull") -> {
                    respond(exchange, 200, """{"type":"pull/ok","t":42}""".toByteArray())
                }
                else -> metadata(exchange, baseURL)
            }
        }
        server.start()
        servers.add(server)
        return TestServer(baseURL)
    }

    private fun respond(
        exchange: HttpExchange,
        status: Int,
        body: ByteArray,
        headers: Map<String, String> = emptyMap()
    ) {
        headers.forEach { (name, value) -> exchange.responseHeaders.set(name, value) }
        exchange.sendResponseHeaders(status, body.size.toLong())
        exchange.responseBody.use { it.write(body) }
    }

    private fun gzip(bytes: ByteArray): ByteArray = ByteArrayOutputStream().use { output ->
        GZIPOutputStream(output).use { it.write(bytes) }
        output.toByteArray()
    }

    private data class TestServer(val baseURL: String)
}
