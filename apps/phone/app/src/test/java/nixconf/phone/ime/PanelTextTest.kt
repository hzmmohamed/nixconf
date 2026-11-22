package nixconf.phone.ime

import nixconf.phone.engine.Engine
import nixconf.phone.session.DictationSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PanelTextTest {
    @Test
    fun engine_label_names_the_server_host() {
        assertEquals("butternut", engineLabel(Engine.Remote("http://butternut:8178")))
        assertEquals("on phone", engineLabel(Engine.Local))
        assertEquals("no server", engineLabel(Engine.Unavailable))
        assertEquals("checking…", engineLabel(null))
    }

    @Test
    fun draft_engine_label() {
        assertEquals("on phone", draftEngineLabel(DictationSession.LOCAL_ENGINE))
        assertEquals("maple", draftEngineLabel("http://maple:8178/"))
        assertNull(draftEngineLabel(null))
    }

    @Test
    fun host_of_garbage_is_the_input() {
        assertEquals("not a url", hostOf("not a url"))
    }

    @Test
    fun elapsed_is_minutes_and_seconds() {
        assertEquals("0:00", elapsed(0))
        assertEquals("0:09", elapsed(9_999))
        assertEquals("1:05", elapsed(65_000))
        assertEquals("0:00", elapsed(-5))
    }

    @Test
    fun kept_text_explains_the_reason() {
        assertEquals("Field changed: kept as draft", keptText(DictationSession.FIELD_CHANGED))
        assertEquals("Kept as draft: odd", keptText("odd"))
    }

    @Test
    fun next_language_cycles() {
        assertEquals("ar", nextLanguage(listOf("en", "ar"), "en"))
        assertEquals("en", nextLanguage(listOf("en", "ar"), "ar"))
        assertEquals("en", nextLanguage(listOf("en", "ar"), "fr"))
        assertEquals("fr", nextLanguage(emptyList(), "fr"))
    }
}
