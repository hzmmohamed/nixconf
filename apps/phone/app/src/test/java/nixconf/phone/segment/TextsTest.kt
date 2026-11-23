package nixconf.phone.segment

import org.junit.Assert.assertEquals
import org.junit.Test

class TextsTest {
    @Test
    fun clean_drops_tags_and_collapses_whitespace() {
        assertEquals("Hello world.", clean("  Hello [BLANK_AUDIO]  world.\n"))
        assertEquals("", clean(" (wind blowing) "))
        assertEquals("", clean("*laughs*"))
        assertEquals("He said (twice) so.", clean("He said (twice) so."))
    }

    @Test
    fun segments_joined_with_one_space_none_before_punctuation() {
        assertEquals("Hello there. how are you?", joinTexts(listOf("Hello there.", "how are you", "?")))
        assertEquals("a b", joinTexts(listOf("a", "", "b")))
        assertEquals("مرحبا، كيف", joinTexts(listOf("مرحبا", "، كيف")))
        assertEquals("x", joined("", "x"))
        assertEquals("y", joined("x ", "y"))
    }
}
