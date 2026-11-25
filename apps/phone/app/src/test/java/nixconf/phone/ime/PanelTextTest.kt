package nixconf.phone.ime

import nixconf.phone.engine.Engine
import nixconf.phone.engine.Where
import nixconf.phone.session.DictationSession
import nixconf.phone.session.Delivery
import nixconf.phone.session.SessionState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PanelTextTest {
    @Test
    fun engine_label_names_the_server_host() {
        assertEquals("butternut", engineLabel(Engine.Remote("http://butternut:8178")))
        assertEquals("on phone", engineLabel(Engine.Local))
        assertEquals("no server · will save as draft", engineLabel(Engine.Unavailable))
        assertEquals("finding server…", engineLabel(null))
    }

    @Test
    fun where_label() {
        assertEquals("Auto", whereLabel(Where.AUTO))
        assertEquals("Phone", whereLabel(Where.PHONE))
    }

    @Test
    fun draft_engine_label() {
        assertEquals("on phone", draftEngineLabel(DictationSession.LOCAL_ENGINE))
        assertEquals("maple", draftEngineLabel("http://maple:8178/"))
        assertNull(draftEngineLabel(null))
    }

    @Test
    fun magicdns_name_shown_as_its_host_label() {
        assertEquals("butternut", engineLabel(Engine.Remote("http://butternut.tail1a9f7c.ts.net:8178")))
        assertEquals("100.105.41.75", hostOf("http://100.105.41.75:8178"))
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
        assertEquals("Saved as draft (field changed)", keptText(DictationSession.FIELD_CHANGED))
        assertEquals("Saved as draft: no server. Transcribes when one is back", keptText(DictationSession.NO_SERVER))
        assertEquals("Nothing heard: check the level bar", keptText(DictationSession.NOTHING_HEARD))
        assertEquals("Removed from the field", keptText(DictationSession.UNDONE))
        assertEquals("Stopped waiting: saved as draft", keptText(DictationSession.STOPPED_WAITING))
        assertEquals("Saved as draft: odd", keptText("odd"))
    }

    private val butternut = Engine.Remote("http://butternut:8178")

    @Test
    fun finishing_says_stopped_until_a_server_answers_then_counts_segments() {
        assertEquals("Stopped · finding server…", finishingText(SessionState.Finishing(null, 1, 3)))
        assertEquals("Finishing 1 of 3 · butternut", finishingText(SessionState.Finishing(butternut, 1, 3)))
        assertEquals("Transcribing… · butternut", finishingText(SessionState.Finishing(butternut)))
        assertEquals("Transcribing… · on phone", finishingText(SessionState.Finishing(Engine.Local, 3, 3)))
    }

    @Test
    fun recording_text_names_the_engine() {
        assertEquals("0:05 · finding server…", recordingText(5_000, SessionState.Recording(null, 0)))
        assertEquals("0:05 · on phone · transcribing…", recordingText(5_000, SessionState.Recording(Engine.Local, 0, true)))
        assertEquals(
            "0:16 · nothing heard yet · stops in 4",
            recordingText(16_000, SessionState.Recording(Engine.Local, 0, stopsInSec = 4)),
        )
    }

    @Test
    fun idle_text_by_field() {
        assertEquals("Tap to dictate", idleText(FieldKind.TEXT, false))
        assertEquals("Tap to dictate · incognito, no draft kept", idleText(FieldKind.TEXT, true))
        assertEquals("Password field: switch keyboard to type", idleText(FieldKind.PASSWORD, false))
        assertEquals("Number field: dictated words may not fit", idleText(FieldKind.NUMERIC, false))
    }

    @Test
    fun announcements_are_short_and_without_the_timer() {
        assertEquals("Recording", announcement(SessionState.Recording(butternut, 0, true), FieldKind.TEXT, false))
        assertEquals(
            "Nothing heard yet, stopping soon",
            announcement(SessionState.Recording(butternut, 0, stopsInSec = 3), FieldKind.TEXT, false),
        )
        assertEquals("Stopped, finding server", announcement(SessionState.Finishing(null), FieldKind.TEXT, false))
        assertEquals("Finishing 2 of 5", announcement(SessionState.Finishing(butternut, 2, 5), FieldKind.TEXT, false))
        assertEquals("Transcribing", announcement(SessionState.Finishing(butternut), FieldKind.TEXT, false))
        assertEquals("Typed", announcement(SessionState.Done("hi"), FieldKind.TEXT, false))
        assertEquals("Tap to dictate", announcement(SessionState.Idle, FieldKind.TEXT, false))
    }

    @Test
    fun mic_description_says_what_a_tap_does() {
        assertEquals("Start dictation", micDescription(SessionState.Idle))
        assertEquals("Stop recording", micDescription(SessionState.Recording(null, 0)))
        assertEquals("Transcribing", micDescription(SessionState.Finishing(null)))
        assertEquals("Start dictation", micDescription(SessionState.Done("x")))
    }

    @Test
    fun drafts_label_and_age() {
        assertEquals("1 draft", draftsLabel(1))
        assertEquals("3 drafts", draftsLabel(3))
        assertEquals("just now", ageText(59_000))
        assertEquals("5 min ago", ageText(5 * 60_000L))
        assertEquals("3 h ago", ageText(3 * 3_600_000L + 1))
        assertEquals("2 d ago", ageText(49 * 3_600_000L))
    }

    @Test
    fun start_errors_in_plain_words() {
        assertEquals("Microphone in use by another app", startError(false, "microphone busy"))
        assertEquals("Microphone in use by another app", startError(false, "microphone unavailable"))
        assertEquals("Can't save the recording: storage full?", startError(true, "cannot create /x"))
        assertEquals("Microphone failed: odd", startError(false, "odd"))
        assertEquals("Microphone failed", startError(false, null))
    }

    @Test
    fun delivery_text_tells_typed_from_gone() {
        assertNull(deliveryText(Delivery.TYPED))
        assertEquals("Already typed or discarded", deliveryText(Delivery.GONE))
        assertEquals("No field to type into", deliveryText(Delivery.NO_FIELD))
    }

    @Test
    fun next_language_cycles() {
        assertEquals("ar", nextLanguage(listOf("en", "ar"), "en"))
        assertEquals("en", nextLanguage(listOf("en", "ar"), "ar"))
        assertEquals("en", nextLanguage(listOf("en", "ar"), "fr"))
        assertEquals("fr", nextLanguage(emptyList(), "fr"))
    }

    @Test
    fun keep_on_label() {
        assertEquals("Keep recording in background", keepOnLabel(false))
        assertEquals("✓ Keeps recording in background", keepOnLabel(true))
    }
}
