package nixconf.phone.diary

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Stands in for android.security.keystore.KeyPermanentlyInvalidatedException, which can't be
 * constructed on the JVM test runner (it's a stub class in android.jar and throws "not mocked").
 * [keyStatusOf] matches by simple class name, so a fake with the same name exercises the real
 * mapping logic without needing the real class or a device.
 */
private class KeyPermanentlyInvalidatedException(message: String) : Exception(message)

class KeyStatusTest {
    @Test
    fun messages() {
        assertEquals(
            "Entries can only be read on this phone. Add a recovery key in Diary settings.",
            keyStatusMessage(KeyStatus.NoRecoveryKey),
        )
        assertEquals(
            "This phone's key is gone; entries can be read with your recovery key.",
            keyStatusMessage(KeyStatus.DeviceKeyLost),
        )
        assertNull(keyStatusMessage(KeyStatus.Ok))
    }

    @Test
    fun unwrap_failure_reports_key_lost() {
        // Mirrors what EntryStore.list/openForRead throws when the device key has been
        // permanently invalidated: KeyUnavailable wraps the Keystore exception as its cause.
        val t = KeyUnavailable(KeyPermanentlyInvalidatedException("screen lock removed"))
        assertEquals(KeyStatus.DeviceKeyLost, keyStatusOf(t, recoverySet = true))
        assertEquals(KeyStatus.DeviceKeyLost, keyStatusOf(t, recoverySet = false))
    }

    @Test
    fun no_failure_with_recovery_set_is_ok() {
        assertEquals(KeyStatus.Ok, keyStatusOf(null, recoverySet = true))
    }

    @Test
    fun no_failure_without_recovery_is_reported() {
        assertEquals(KeyStatus.NoRecoveryKey, keyStatusOf(null, recoverySet = false))
    }

    @Test
    fun unrelated_failure_without_recovery_is_still_no_recovery_key() {
        // An ordinary KeyUnavailable (wrong key, not invalidation) with no recovery key set:
        // still reported as NoRecoveryKey, not DeviceKeyLost.
        val t = KeyUnavailable(java.io.IOException("no recipient matches"))
        assertEquals(KeyStatus.NoRecoveryKey, keyStatusOf(t, recoverySet = false))
    }
}
