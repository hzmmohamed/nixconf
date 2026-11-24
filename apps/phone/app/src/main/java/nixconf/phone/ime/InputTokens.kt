package nixconf.phone.ime

// The focused input session as a token: package/field id is not enough
// (WebView inputs and chat conversations reuse the same field id), so a
// generation counter bumps on every new input and when the input finishes.
// A restart of the same input (restarting = true) keeps the token.
class InputTokens {
    private var generation = 0L

    var token: String? = null
        private set

    /** The token without the generation: the same field, focused again later. */
    var field: String? = null
        private set

    fun start(packageName: String?, fieldId: Int, restarting: Boolean) {
        if (!restarting) generation++
        field = "$packageName/$fieldId"
        token = "$field#$generation"
    }

    fun finish() {
        generation++
        token = null
        field = null
    }
}
