package nixconf.phone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class InputTokensTest {
    private val tokens = InputTokens()

    @Test
    fun same_field_new_input_session_gets_a_new_token() {
        // WebView inputs and chat conversations reuse package + field id.
        tokens.start("org.chat", 7, restarting = false)
        val first = tokens.token
        assertNotNull(first)
        tokens.finish()
        assertNull(tokens.token)
        tokens.start("org.chat", 7, restarting = false)
        assertNotEquals(first, tokens.token)
    }

    @Test
    fun new_input_without_finish_still_changes_the_token() {
        tokens.start("org.chat", 7, restarting = false)
        val first = tokens.token
        tokens.start("org.chat", 7, restarting = false)
        assertNotEquals(first, tokens.token)
    }

    @Test
    fun restarting_the_same_input_keeps_the_token() {
        tokens.start("org.notes", 42, restarting = false)
        val first = tokens.token
        tokens.start("org.notes", 42, restarting = true)
        assertEquals(first, tokens.token)
    }

    @Test
    fun different_fields_differ() {
        tokens.start("org.notes", 42, restarting = false)
        val a = tokens.token
        tokens.start("org.notes", 43, restarting = true)
        assertNotEquals(a, tokens.token)
    }
}
