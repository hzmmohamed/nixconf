package nixconf.phone.diary

import org.junit.Assert.assertTrue
import org.junit.Test

class UlidTest {
    @Test
    fun length_and_alphabet() {
        val id = Ulid.next(1_795_000_000_000L)
        assertTrue(id.length == 26)
        assertTrue(Regex("""[0-9A-HJKMNP-TV-Z]{26}""").matches(id))
    }

    @Test
    fun sorts_by_time() {
        val a = Ulid.next(1000L)
        val b = Ulid.next(2000L)
        assertTrue(a < b)
    }

    @Test
    fun monotonic_same_ms() {
        val ids = (1..1000).map { Ulid.next(5L) }
        for (i in 1 until ids.size) {
            assertTrue(ids[i - 1] < ids[i])
        }
    }
}
