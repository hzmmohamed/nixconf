package nixconf.phone.ime

import nixconf.phone.drafts.TIER_PERSONAL
import nixconf.phone.drafts.TIER_WORK
import org.junit.Assert.assertEquals
import org.junit.Test

// Same cases as dictate-stream's tier_for (tests/test_capture.py), with packages.
class TierTest {
    private val work = listOf("com.example.agent")

    @Test
    fun work_list_decides_unless_overridden() {
        assertEquals(TIER_WORK, tierFor("com.example.agent", work, null))
        assertEquals(TIER_PERSONAL, tierFor("com.example.chat", work, null))
        assertEquals(TIER_PERSONAL, tierFor(null, work, null))
        assertEquals(TIER_PERSONAL, tierFor("", work, null))
        assertEquals(TIER_WORK, tierFor("com.example.chat", work, TIER_WORK))
        assertEquals(TIER_PERSONAL, tierFor("com.example.agent", work, TIER_PERSONAL))
        assertEquals(TIER_WORK, tierFor("com.example.agent", work, "bogus"))
    }

    @Test
    fun package_match_is_exact() {
        assertEquals(TIER_PERSONAL, tierFor("com.example.agent.beta", work, null))
        assertEquals(TIER_PERSONAL, tierFor("COM.EXAMPLE.AGENT", work, null))
    }

    @Test
    fun flip_goes_to_the_other_tier() {
        assertEquals(TIER_PERSONAL, flipped(TIER_WORK))
        assertEquals(TIER_WORK, flipped(TIER_PERSONAL))
    }
}
