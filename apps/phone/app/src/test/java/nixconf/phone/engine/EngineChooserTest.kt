package nixconf.phone.engine

import java.io.IOException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class) // currentTime
class EngineChooserTest {
    private val a = "http://butternut:8178"
    private val b = "http://peacelily:8178"

    @Test
    fun first_listed_reachable_wins() = runTest {
        val engine = chooseEngine(listOf(a, b), "en", localReady = true, localLanguage = "en") { url ->
            delay(if (url == a) 300 else 10)
            true
        }
        assertEquals(Engine.Remote(a), engine)
    }

    @Test
    fun later_server_wins_when_first_is_down_and_probes_run_in_parallel() = runTest {
        val engine = chooseEngine(listOf(a, b), "en", localReady = false, localLanguage = "en") { url ->
            delay(1000)
            if (url == a) throw IOException("refused") else true
        }
        assertEquals(Engine.Remote(b), engine)
        assertTrue("probes ran one after the other", currentTime < 2000)
    }

    @Test
    fun falls_back_to_local_for_english() = runTest {
        val engine = chooseEngine(listOf(a), "en", localReady = true, localLanguage = "en") { false }
        assertEquals(Engine.Local, engine)
        assertEquals(Engine.Local, chooseEngine(emptyList(), "en", true, "en") { true })
    }

    @Test
    fun unavailable_for_arabic_without_server() = runTest {
        assertEquals(Engine.Unavailable, chooseEngine(listOf(a), "ar", localReady = true, localLanguage = "en") { false })
    }

    @Test
    fun unavailable_when_local_not_ready() = runTest {
        assertEquals(Engine.Unavailable, chooseEngine(listOf(a), "en", localReady = false, localLanguage = "en") { false })
    }

    @Test
    fun phone_mode_uses_the_phone_without_probing() = runTest {
        var probed = false
        val engine = chooseEngine(listOf(a), "en", localReady = true, localLanguage = "en", where = Where.PHONE) {
            probed = true
            true
        }
        assertEquals(Engine.Local, engine)
        assertFalse("a probe wakes the server", probed)
    }

    @Test
    fun phone_mode_still_uses_a_server_for_what_the_phone_cannot_do() = runTest {
        assertEquals(Engine.Remote(a), chooseEngine(listOf(a), "ar", true, "en", where = Where.PHONE) { true })
        assertEquals(Engine.Remote(a), chooseEngine(listOf(a), "en", false, "en", where = Where.PHONE) { true })
    }

    @Test
    fun auto_passes_over_a_server_on_battery_for_the_next_one() = runTest {
        val probed = mutableListOf<String>()
        val engine = chooseEngine(listOf(a, b), "en", true, "en", onBattery = { it == a }) { url ->
            probed += url
            true
        }
        assertEquals(Engine.Remote(b), engine)
        assertEquals("the server on battery is not woken", listOf(b), probed)
    }

    @Test
    fun auto_prefers_the_phone_over_a_server_on_battery() = runTest {
        var probed = false
        val engine = chooseEngine(listOf(a), "en", true, "en", onBattery = { true }) {
            probed = true
            true
        }
        assertEquals(Engine.Local, engine)
        assertFalse(probed)
    }

    @Test
    fun a_server_on_battery_is_used_when_nothing_else_can() = runTest {
        assertEquals(Engine.Remote(a), chooseEngine(listOf(a), "ar", true, "en", onBattery = { true }) { true })
        assertEquals(Engine.Unavailable, chooseEngine(listOf(a), "ar", true, "en", onBattery = { true }) { false })
    }

    @Test
    fun unknown_or_failing_power_status_counts_as_plugged_in() = runTest {
        assertEquals(Engine.Remote(a), chooseEngine(listOf(a), "en", true, "en", onBattery = { null }) { true })
        assertEquals(
            Engine.Remote(a),
            chooseEngine(listOf(a), "en", true, "en", onBattery = { throw IOException("refused") }) { true },
        )
    }

    @Test
    fun where_cycles_and_parses() {
        assertEquals(Where.PHONE, Where.AUTO.next())
        assertEquals(Where.AUTO, Where.PHONE.next())
        assertEquals(Where.PHONE, Where.of("PHONE"))
        assertEquals(Where.AUTO, Where.of(null))
        assertEquals(Where.AUTO, Where.of("garbage"))
    }
}
