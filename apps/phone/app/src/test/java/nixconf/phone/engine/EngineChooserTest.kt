package nixconf.phone.engine

import java.io.IOException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
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
}
