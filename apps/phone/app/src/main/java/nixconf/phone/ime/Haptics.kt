package nixconf.phone.ime

import android.view.HapticFeedbackConstants
import nixconf.phone.session.SessionState

/**
 * Haptics at the moments the user is looking at the field, not the panel:
 * start (firm), stop (a tick), typed (confirm), saved as a draft (reject).
 * Nothing per segment. View.performHapticFeedback follows the system setting.
 */
enum class Haptic(val constant: Int) {
    START(HapticFeedbackConstants.LONG_PRESS),
    STOP(HapticFeedbackConstants.CLOCK_TICK),
    TYPED(HapticFeedbackConstants.CONFIRM),
    SAVED(HapticFeedbackConstants.REJECT),
}

/** The haptic for going from [before] to [after], if any. */
fun hapticFor(before: SessionState, after: SessionState): Haptic? = when {
    after is SessionState.Recording && before !is SessionState.Recording -> Haptic.START
    after is SessionState.Finishing && before is SessionState.Recording -> Haptic.STOP
    after is SessionState.Done && before !is SessionState.Done -> Haptic.TYPED
    after is SessionState.Kept && (before is SessionState.Recording || before is SessionState.Finishing) -> Haptic.SAVED
    else -> null
}
