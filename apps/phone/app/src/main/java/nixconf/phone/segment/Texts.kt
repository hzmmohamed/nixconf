package nixconf.phone.segment

// Segment texts, as on the desktop (dictate-stream.py, clean/joined): one
// space between segments, none before punctuation.

private const val NO_SPACE_BEFORE = ".,;:!?)]}…%،؛؟"
private val TAGS = Regex("""\[[^\]]*\]|^\s*\([^)]*\)\s*$|^\s*\*[^*]*\*\s*$""")

/** Whisper's text without [tags], a lone (sound) or *action*, whitespace collapsed. */
fun clean(text: String): String = TAGS.replace(text, "").split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")

/** [text] as it follows [prev]: with a leading space unless one is not wanted. */
fun joined(prev: String, text: String): String =
    if (prev.isEmpty() || text.isEmpty() || text[0] in NO_SPACE_BEFORE || prev.last().isWhitespace()) text else " $text"

fun joinTexts(texts: List<String>): String = texts.fold("") { out, t -> out + joined(out, t) }

/**
 * The space [text] needs before it in a field whose text before the cursor
 * ends in [before] (null: the field cannot say): the [joined] rule at the
 * field's edge, so a burst after a word (or after ⌫) does not glue to it.
 */
fun spaceBefore(before: String?, text: String): String =
    if (before.isNullOrEmpty() || joined(before, text) == text) "" else " "

/** The space after typed text: none when the field already has a space (or punctuation) right after the cursor. */
fun spaceAfter(after: String?): String =
    if (!after.isNullOrEmpty() && (after[0].isWhitespace() || after[0] in NO_SPACE_BEFORE)) "" else " "
