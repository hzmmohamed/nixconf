package nixconf.phone.ime

// The focused input session as a token: package/field id is not enough
// (WebView inputs and chat conversations reuse the same field id), so a
// generation counter bumps on every new input and when the input finishes.
// A restart of the same input (restarting = true) keeps the token.
class InputTokens {
    private var generation = 0L

    var token: String? = null
        private set

    fun start(packageName: String?, fieldId: Int, restarting: Boolean) {
        if (!restarting) generation++
        token = "$packageName/$fieldId#$generation"
    }

    fun finish() {
        generation++
        token = null
    }
}
