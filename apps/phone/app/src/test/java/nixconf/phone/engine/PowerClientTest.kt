package nixconf.phone.engine

import java.io.IOException
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

class PowerClientTest {
    private val server = MockWebServer().apply { start() }
    private val client = PowerClient(OkHttpClient())
    private val url = server.url("/power.json").toString()

    @After
    fun shutdown() = server.shutdown()

    @Test
    fun reads_on_battery() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"onBattery":true}"""))
        assertEquals(true, client.onBattery(url))
        server.enqueue(MockResponse().setBody("""{"onBattery":false}"""))
        assertEquals(false, client.onBattery(url))
    }

    @Test
    fun unknown_when_missing_or_unreadable() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(404))
        assertNull(client.onBattery(url))
        server.enqueue(MockResponse().setBody("not json"))
        assertNull(client.onBattery(url))
        server.enqueue(MockResponse().setBody("""{"other":1}"""))
        assertNull(client.onBattery(url))
    }

    @Test
    fun throws_when_nothing_listens() = runBlocking {
        server.shutdown()
        try {
            client.onBattery(url)
            fail("expected IOException")
        } catch (e: IOException) {
            // The chooser probes the server anyway.
        }
    }
}
