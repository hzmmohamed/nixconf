package nixconf.phone.diary

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.interfaces.RSAPublicKey
import java.security.spec.X509EncodedKeySpec
import java.util.Base64

// Device key: RSA-3072 in AndroidKeyStore, alias "diary-device-v<N>" (N starts at 1 and only
// ever goes up, on a DeviceKeyLost rotation - see [DeviceKeys.publicRecipients]). It's locked
// behind biometric/device-credential auth (setUserAuthenticationRequired) so a passive snoop
// with the phone unlocked-but-idle can't read entries just by opening the list; encryption
// itself (wrapping a fresh entry key to the device's *public* key) is done in software from the
// exported public key, so capture never waits on auth (constraints.md: "Capture never depends
// on unlock"). The recovery key is the user's own backup: its public half lives in
// SharedPreferences (pasted in, see RecoveryKey.parsePem), its private half never touches this
// phone - apps/phone/tools/diary_recover.py is the only thing that ever uses it.

private const val PREFS = "diary"
private const val PREF_DEVICE_KEY_VERSION = "deviceKeyVersion"
private const val PREF_RECOVERY_PEM = "recoveryPem"
private const val ALIAS_PREFIX = "diary-device-v"
private const val ANDROID_KEYSTORE = "AndroidKeyStore"
private const val RSA_KEY_SIZE = 3072
private const val USER_AUTH_WINDOW_SECONDS = 300

enum class KeyStatus { Ok, NoRecoveryKey, DeviceKeyLost }

/**
 * The exact copy shown for [s], or null when there's nothing to say. Never mentions entry
 * content - these are process states, not diary data.
 */
fun keyStatusMessage(s: KeyStatus): String? = when (s) {
    KeyStatus.NoRecoveryKey -> "Entries can only be read on this phone. Add a recovery key in Diary settings."
    KeyStatus.DeviceKeyLost -> "This phone's key is gone; entries can be read with your recovery key."
    KeyStatus.Ok -> null
}

/**
 * Pure mapping from a failure (if any) plus whether a recovery key is set, to [KeyStatus]. [t]
 * is what a caller saw trying to use the device key - e.g. the [KeyUnavailable] an
 * [EntryStore.list]/[EntryStore.openForRead] call threw, or null when nothing failed.
 *
 * `KeyPermanentlyInvalidatedException` (thrown by AndroidKeyStore once its auth enrollment
 * changes - e.g. the screen lock is removed) means [KeyStatus.DeviceKeyLost], whether it's [t]
 * itself or buried in a cause chain (that's how it arrives wrapped in [KeyUnavailable]).
 * `UserNotAuthenticatedException` is deliberately not matched here: that's "ask for unlock",
 * not a status this function reports - the caller (Task 8) shows BiometricPrompt instead.
 *
 * Matched by simple class name, not `is KeyPermanentlyInvalidatedException`: that real class
 * lives in android.jar stubs and throws "not mocked" if ever constructed on the JVM test
 * runner, so [KeyStatusTest] exercises this with a fake class of the same simple name instead
 * of the real one - matching by name keeps that test honest about what it's actually proving
 * (the mapping logic) while staying constructible outside a device/emulator.
 */
fun keyStatusOf(t: Throwable?, recoverySet: Boolean): KeyStatus {
    if (isKeyPermanentlyInvalidated(t)) return KeyStatus.DeviceKeyLost
    if (!recoverySet) return KeyStatus.NoRecoveryKey
    return KeyStatus.Ok
}

private fun isKeyPermanentlyInvalidated(t: Throwable?): Boolean {
    var cur: Throwable? = t
    var hops = 0
    while (cur != null && hops < 16) {
        if (cur.javaClass.simpleName == "KeyPermanentlyInvalidatedException") return true
        cur = cur.cause
        hops++
    }
    return false
}

/** Parses and fingerprints a recovery key's *public* half, pasted in as PEM. */
object RecoveryKey {
    /**
     * [text] must be an SPKI "-----BEGIN PUBLIC KEY-----" PEM of an RSA key >= 3072 bits.
     * A private key (PKCS8 "BEGIN PRIVATE KEY", or PKCS1 "BEGIN RSA PRIVATE KEY") gets a
     * specific error so the user knows they pasted the wrong half.
     */
    fun parsePem(text: String): Result<PublicKey> {
        if (text.contains("BEGIN PRIVATE KEY") || text.contains("BEGIN RSA PRIVATE KEY")) {
            return Result.failure(IllegalArgumentException("this is a private key; paste the public one"))
        }
        if (!text.contains("BEGIN PUBLIC KEY")) {
            return Result.failure(IllegalArgumentException("not a public key (PEM)"))
        }
        val der = try {
            val b64 = text.lineSequence().filterNot { it.contains("-----") }.joinToString("").filterNot { it.isWhitespace() }
            Base64.getDecoder().decode(b64)
        } catch (e: IllegalArgumentException) {
            return Result.failure(IllegalArgumentException("not a public key (PEM)"))
        }
        val key = try {
            KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(der))
        } catch (e: Exception) {
            return Result.failure(IllegalArgumentException("not a public key (PEM)"))
        }
        val rsa = key as? RSAPublicKey ?: return Result.failure(IllegalArgumentException("not a public key (PEM)"))
        if (rsa.modulus.bitLength() < RSA_KEY_SIZE) {
            return Result.failure(IllegalArgumentException("needs RSA 3072 or larger"))
        }
        return Result.success(key)
    }

    /** First 16 hex chars of SHA-256(SPKI DER), lowercase, grouped by 4 with spaces: "ab12 cd34 ef56 7890". */
    fun fingerprint(key: PublicKey): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(key.encoded)
        val hex = digest.joinToString("") { "%02x".format(it) }.take(16)
        return hex.chunked(4).joinToString(" ")
    }
}

/**
 * The device's own Keystore key (generation, export, auth-gated private access) plus the
 * recovery key preference. Thin by design: no UI here (BiometricPrompt is Task 8).
 */
class DeviceKeys(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    /** SharedPreferences-backed; null means no recovery key has been set. */
    var recoveryPem: String?
        get() = prefs.getString(PREF_RECOVERY_PEM, null)
        set(value) = prefs.edit().putString(PREF_RECOVERY_PEM, value).apply()

    /**
     * Current device key alias, e.g. "diary-device-v1". Creates v1 on first use (no
     * [PREF_DEVICE_KEY_VERSION] pref yet); if a version is recorded but its alias is gone from
     * the Keystore (the "DeviceKeyLost" case where the entry itself disappeared), rotates
     * forward and creates the next one - that's what makes the *next* [publicRecipients] call
     * use a fresh key without the caller having to do anything.
     */
    private fun currentAlias(): String {
        if (!prefs.contains(PREF_DEVICE_KEY_VERSION)) {
            val alias = "${ALIAS_PREFIX}1"
            generate(alias)
            prefs.edit().putInt(PREF_DEVICE_KEY_VERSION, 1).apply()
            return alias
        }
        val version = prefs.getInt(PREF_DEVICE_KEY_VERSION, 1)
        val alias = "$ALIAS_PREFIX$version"
        if (keyStore.containsAlias(alias)) return alias
        val next = version + 1
        val nextAlias = "$ALIAS_PREFIX$next"
        generate(nextAlias)
        prefs.edit().putInt(PREF_DEVICE_KEY_VERSION, next).apply()
        return nextAlias
    }

    private fun generate(alias: String) {
        val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, ANDROID_KEYSTORE)
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(RSA_KEY_SIZE)
            .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA1)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
            .setUserAuthenticationRequired(true)
            .setUserAuthenticationParameters(
                USER_AUTH_WINDOW_SECONDS,
                KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL,
            )
            .setInvalidatedByBiometricEnrollment(false)
            .build()
        gen.initialize(spec)
        gen.generateKeyPair()
    }

    /** The device key's public half, re-derived from the Keystore certificate so it never needs auth. */
    private fun publicKeyFor(alias: String): PublicKey {
        val cert = keyStore.getCertificate(alias)
        return KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(cert.publicKey.encoded))
    }

    /**
     * The device recipient (current alias, [OAEP_DEVICE]) plus the recovery recipient when set
     * ([OAEP_SHA256]). Creates the device key on first use; needs no auth to call.
     */
    fun publicRecipients(): List<Recipient> {
        val alias = currentAlias()
        val recipients = mutableListOf(Recipient("device:$alias", publicKeyFor(alias), OAEP_DEVICE))
        recoveryPem?.let { pem ->
            RecoveryKey.parsePem(pem).getOrNull()?.let { key ->
                recipients += Recipient("recovery:${RecoveryKey.fingerprint(key).replace(" ", "")}", key, OAEP_SHA256)
            }
        }
        return recipients
    }

    /** The current device key's private half; throws UserNotAuthenticatedException when locked. */
    fun privateKey(): PrivateKey {
        val alias = currentAlias()
        return keyStore.getKey(alias, null) as PrivateKey
    }

    /**
     * [KeyPermanentlyInvalidatedException] (screen lock removed, biometrics reset) leaves the
     * Keystore *entry* in place but unusable for crypto ops - unlike the alias simply being
     * gone, [currentAlias] can't detect that on its own. A caller that unwraps the device key
     * (Task 7/8) and sees that exception (wrapped in [KeyUnavailable] from [EntryStore]) calls
     * this once, so the *next* [publicRecipients] rotates forward instead of handing out
     * recipients for a key that can never decrypt again.
     */
    fun reportKeyLost() {
        val version = prefs.getInt(PREF_DEVICE_KEY_VERSION, 1)
        val alias = "$ALIAS_PREFIX$version"
        try {
            keyStore.deleteEntry(alias)
        } catch (e: Exception) {
            // Best effort: currentAlias()'s containsAlias check is what actually matters.
        }
    }

    /** [KeyStatus] for whatever the caller last saw unwrapping the device key (null if nothing failed). */
    fun status(lastError: Throwable? = null): KeyStatus = keyStatusOf(lastError, recoverySet = recoveryPem != null)
}
