package nixconf.phone.diary

import android.util.Log

/**
 * Log seam for the diary module: code logs through [DiaryLog], never android.util.Log
 * directly, so tests can replace [sink] instead of the whole suite's mocking being weakened
 * (android.util.Log is a stub that throws "not mocked" on the JVM test runner; this is the
 * alternative to `testOptions.unitTests.isReturnDefaultValues`, which would silence that for
 * every class, not just this one). Ids and sizes only, per constraints.md - never entry content.
 */
internal object DiaryLog {
    var sink: (priority: Int, msg: String) -> Unit = { priority, msg -> Log.println(priority, "PollenDiary", msg) }

    fun i(msg: String) = sink(Log.INFO, msg)

    fun w(msg: String) = sink(Log.WARN, msg)
}
