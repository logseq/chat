package logseq.chat.model

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.runBlocking
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class AndroidGraphSSETransportTests {
    private val servers = mutableListOf<HttpServer>()

    @AfterTest
    fun tearDown() {
        servers.forEach { it.stop(0) }
    }

    @Test
    fun opensAuthorizedEventStreamAtTheAppliedCursorAndPreservesFrameBoundaries() {
        runBlocking {
            val rawPath = AtomicReference<String>()
            val rawQuery = AtomicReference<String>()
            val authorization = AtomicReference<String>()
            val accept = AtomicReference<String>()
            val server = server { exchange ->
                rawPath.set(exchange.requestURI.rawPath)
                rawQuery.set(exchange.requestURI.rawQuery)
                authorization.set(exchange.requestHeaders.getFirst("Authorization"))
                accept.set(exchange.requestHeaders.getFirst("Accept"))
                exchange.responseHeaders.add("Content-Type", "text/event-stream")
                exchange.sendResponseHeaders(200, 0)
                exchange.responseBody.use { output ->
                    output.write(": heartbeat\n\n".toByteArray())
                    output.flush()
                    output.write("id: 43\r\nevent: graph-changes\r\ndata: payload\r\n\r\n".toByteArray())
                }
            }

            val stream = AndroidGraphSSETransport.open(
                baseURL = "${server.baseURL}/api",
                graphID = "graph id",
                appliedServerT = 42,
                accessToken = "access-token"
            )
            try {
                assertEquals(": heartbeat\n\n", stream.nextFrame())
                assertEquals("id: 43\r\nevent: graph-changes\r\ndata: payload\r\n\r\n", stream.nextFrame())
                assertEquals(null, stream.nextFrame())
            } finally {
                stream.close()
            }

            assertEquals("/sync/graph%20id/events", rawPath.get())
            assertEquals("since=42", rawQuery.get())
            assertEquals("Bearer access-token", authorization.get())
            assertEquals("text/event-stream", accept.get())
        }
    }

    @Test
    fun rejectsUnsuccessfulEventResponse() {
        runBlocking {
            val server = server { exchange -> respond(exchange, 403, "forbidden") }

            assertFailsWith<AndroidGraphSSETransportException> {
                AndroidGraphSSETransport.open(
                    baseURL = server.baseURL,
                    graphID = "graph",
                    appliedServerT = 7,
                    accessToken = "token"
                )
            }
        }
    }

    private fun server(handler: (HttpExchange) -> Unit): TestServer {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/", handler)
        server.start()
        servers.add(server)
        return TestServer("http://127.0.0.1:${server.address.port}")
    }

    private fun respond(exchange: HttpExchange, status: Int, body: String) {
        val bytes = body.toByteArray()
        exchange.sendResponseHeaders(status, bytes.size.toLong())
        exchange.responseBody.use { it.write(bytes) }
    }

    private data class TestServer(val baseURL: String)
}
