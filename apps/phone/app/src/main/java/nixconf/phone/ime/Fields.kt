package nixconf.phone.ime

import android.text.InputType
import android.view.inputmethod.EditorInfo

// What the focused field means for dictation, from its EditorInfo; plain
// functions over the ints so they can be tested on the JVM.

enum class FieldKind {
    TEXT,

    /** No dictation at all: the audio and text would be stored in a draft. */
    PASSWORD,

    /** Number, phone and date fields: dictated words may be rejected or garbled (a warning). */
    NUMERIC,
}

fun fieldKind(inputType: Int): FieldKind {
    val variation = inputType and InputType.TYPE_MASK_VARIATION
    return when (inputType and InputType.TYPE_MASK_CLASS) {
        InputType.TYPE_CLASS_TEXT -> if (variation in TEXT_PASSWORDS) FieldKind.PASSWORD else FieldKind.TEXT
        InputType.TYPE_CLASS_NUMBER ->
            if (variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD) FieldKind.PASSWORD else FieldKind.NUMERIC
        InputType.TYPE_CLASS_PHONE, InputType.TYPE_CLASS_DATETIME -> FieldKind.NUMERIC
        else -> FieldKind.TEXT // TYPE_NULL: a terminal or raw-key editor, text goes in as typed
    }
}

private val TEXT_PASSWORDS = setOf(
    InputType.TYPE_TEXT_VARIATION_PASSWORD,
    InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
    InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
)

/** The app asked for no personalized learning (incognito tabs, private chats). */
fun incognito(imeOptions: Int): Boolean = imeOptions and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING != 0

/** The editor action the enter key performs (Send, Search, …); null: it types a newline. */
fun enterAction(imeOptions: Int): Int? {
    if (imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION != 0) return null
    return when (val action = imeOptions and EditorInfo.IME_MASK_ACTION) {
        EditorInfo.IME_ACTION_GO,
        EditorInfo.IME_ACTION_SEARCH,
        EditorInfo.IME_ACTION_SEND,
        EditorInfo.IME_ACTION_NEXT,
        EditorInfo.IME_ACTION_DONE,
        EditorInfo.IME_ACTION_PREVIOUS,
        -> action
        else -> null
    }
}

/** The enter key's label for [enterAction]'s result. */
fun enterLabel(action: Int?): String = when (action) {
    EditorInfo.IME_ACTION_GO -> "Go"
    EditorInfo.IME_ACTION_SEARCH -> "Search"
    EditorInfo.IME_ACTION_SEND -> "Send"
    EditorInfo.IME_ACTION_NEXT -> "Next"
    EditorInfo.IME_ACTION_DONE -> "Done"
    EditorInfo.IME_ACTION_PREVIOUS -> "Previous"
    else -> NEWLINE
}

const val NEWLINE = "↵"

/**
 * Back to the user's other keyboard: the previous one; if there is none
 * (right after enabling this one, or the system forgot it), the next one;
 * failing that, the system picker. Never a dead end on a panel that cannot type.
 */
fun switchAway(previous: () -> Boolean, next: () -> Boolean, picker: () -> Unit) {
    if (previous() || next()) return
    picker()
}
