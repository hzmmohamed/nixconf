package nixconf.phone.ime

import android.text.InputType
import android.view.inputmethod.EditorInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FieldsTest {
    private val text = InputType.TYPE_CLASS_TEXT

    @Test
    fun passwords_get_no_dictation() {
        assertEquals(FieldKind.PASSWORD, fieldKind(text or InputType.TYPE_TEXT_VARIATION_PASSWORD))
        assertEquals(FieldKind.PASSWORD, fieldKind(text or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD))
        assertEquals(FieldKind.PASSWORD, fieldKind(text or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD))
        assertEquals(
            FieldKind.PASSWORD,
            fieldKind(InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD),
        )
    }

    @Test
    fun numbers_phones_and_dates_are_numeric() {
        assertEquals(FieldKind.NUMERIC, fieldKind(InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL))
        assertEquals(FieldKind.NUMERIC, fieldKind(InputType.TYPE_CLASS_PHONE))
        assertEquals(FieldKind.NUMERIC, fieldKind(InputType.TYPE_CLASS_DATETIME or InputType.TYPE_DATETIME_VARIATION_DATE))
    }

    @Test
    fun text_fields_are_text() {
        assertEquals(FieldKind.TEXT, fieldKind(text or InputType.TYPE_TEXT_FLAG_MULTI_LINE))
        assertEquals(FieldKind.TEXT, fieldKind(text or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS))
        assertEquals(FieldKind.TEXT, fieldKind(text or InputType.TYPE_TEXT_VARIATION_URI))
        assertEquals(FieldKind.TEXT, fieldKind(InputType.TYPE_NULL))
    }

    @Test
    fun incognito_flag() {
        assertTrue(incognito(EditorInfo.IME_ACTION_GO or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING))
        assertFalse(incognito(EditorInfo.IME_ACTION_GO))
    }

    @Test
    fun enter_performs_the_editor_action_unless_it_types_a_newline() {
        assertEquals(EditorInfo.IME_ACTION_SEND, enterAction(EditorInfo.IME_ACTION_SEND))
        assertEquals("Send", enterLabel(enterAction(EditorInfo.IME_ACTION_SEND)))
        assertEquals("Search", enterLabel(enterAction(EditorInfo.IME_ACTION_SEARCH)))
        // Multi-line fields ask for a newline even with an action.
        assertNull(enterAction(EditorInfo.IME_ACTION_SEND or EditorInfo.IME_FLAG_NO_ENTER_ACTION))
        assertNull(enterAction(EditorInfo.IME_ACTION_UNSPECIFIED))
        assertNull(enterAction(EditorInfo.IME_ACTION_NONE))
        assertEquals(NEWLINE, enterLabel(null))
    }

    @Test
    fun switch_tries_previous_then_next_then_the_picker() {
        val calls = mutableListOf<String>()
        fun run(previous: Boolean, next: Boolean): List<String> {
            calls.clear()
            switchAway({ calls += "previous"; previous }, { calls += "next"; next }, { calls += "picker" })
            return calls.toList()
        }
        assertEquals(listOf("previous"), run(previous = true, next = true))
        assertEquals(listOf("previous", "next"), run(previous = false, next = true))
        assertEquals(listOf("previous", "next", "picker"), run(previous = false, next = false))
    }
}
