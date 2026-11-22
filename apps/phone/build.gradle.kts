// Built through `nix run .#phone-app -- build|test` (modules/packages/phone-app.nix),
// which provides Gradle, JDK 17, the Android SDK and the sherpa-onnx AAR.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
}
