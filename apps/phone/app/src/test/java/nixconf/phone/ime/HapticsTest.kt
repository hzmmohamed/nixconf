package nixconf.phone.ime

import nixconf.phone.drafts.Draft
import nixconf.phone.drafts.DraftStatus
import nixconf.phone.engine.Engine
import nixconf.phone.session.SessionState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HapticsTest {
    private val recording = SessionState.Recording(null, 0)
    private val finishing = SessionState.Finishing(Engine.Local)
    private val kept = SessionState.Kept(
        Draft("d", java.io.File("d"), DraftStatus.PENDING, 0, "en", null, "hi", null),
        "field changed",
    )

    @Test
    fun start_stop_and_result() {
        assertEquals(Haptic.START, hapticFor(SessionState.Idle, recording))
        assertEquals(Haptic.START, hapticFor(SessionState.Done("x"), recording))
        assertEquals(Haptic.STOP, hapticFor(recording, finishing))
        assertEquals(Haptic.TYPED, hapticFor(finishing, SessionState.Done("x")))
        assertEquals(Haptic.SAVED, hapticFor(finishing, kept))
        assertEquals(Haptic.TYPED, hapticFor(kept, SessionState.Done("hi"))) // Insert here
    }

    @Test
    fun nothing_for_updates_within_a_state() {
        assertNull(hapticFor(recording, recording.copy(engine = Engine.Local, transcribing = true)))
        assertNull(hapticFor(finishing, SessionState.Finishing(Engine.Local, 1, 3)))
        assertNull(hapticFor(SessionState.Done("x"), SessionState.Idle)) // new input
        assertNull(hapticFor(recording, SessionState.Idle)) // cancel
    }
}
