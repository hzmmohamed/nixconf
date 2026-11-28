import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "nixconf.phone"
    compileSdk = 36
    // The Nix SDK is read-only: pin what it ships so AGP never tries to install.
    buildToolsVersion = "36.0.0"

    defaultConfig {
        applicationId = "nixconf.phone"
        minSdk = 31
        targetSdk = 36
        // `phone-app build` passes git's commit count and short rev.
        versionCode = providers.gradleProperty("versionCode").orNull?.toInt() ?: 1
        versionName = providers.gradleProperty("versionName").orNull ?: "dev"
        // Default profile URL: `phone-app` passes the serving host's
        // (dictation-server phone.url, flake data); empty means set it in the app.
        val profileUrl = providers.gradleProperty("profileUrl").orNull.orEmpty()
        buildConfigField("String", "PROFILE_URL", "\"$profileUrl\"")
        ndk { abiFilters += "arm64-v8a" }
    }

    // Release key outside git: -PreleaseStoreFile=<jks> and
    // -PsigningProperties=<file with storePassword, keyAlias, keyPassword>
    // (a file, so the passwords never show up in a command line).
    // Alpha (CI test builds): the same with -PalphaStoreFile / -PalphaSigningProperties,
    // a key of its own so alpha updates install over each other.
    fun signingProps(name: String) = providers.gradleProperty(name).orNull?.let { path ->
        Properties().apply { file(path).inputStream().use { load(it) } }
    }
    val releaseStore = providers.gradleProperty("releaseStoreFile").orNull
    val releaseProps = signingProps("signingProperties")
    val alphaStore = providers.gradleProperty("alphaStoreFile").orNull
    val alphaProps = signingProps("alphaSigningProperties")
    signingConfigs {
        for ((name, store, props) in listOf(Triple("release", releaseStore, releaseProps), Triple("alpha", alphaStore, alphaProps))) {
            if (store != null && props != null) {
                create(name) {
                    storeFile = file(store)
                    storePassword = props.getProperty("storePassword")
                    keyAlias = props.getProperty("keyAlias")
                    keyPassword = props.getProperty("keyPassword")
                }
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
            // sherpa-onnx is reached through JNI: no shrinking.
            isMinifyEnabled = false
        }
        // CI test builds ("Pollen α"): a debug build under its own application id,
        // installed next to the real Pollen, so a test build never touches its data.
        create("alpha") {
            initWith(getByName("debug"))
            applicationIdSuffix = ".alpha"
            versionNameSuffix = "-alpha"
            signingConfig = signingConfigs.findByName("alpha") ?: signingConfigs.getByName("debug")
            matchingFallbacks += "debug"
        }
    }

    // Release lint would fetch its own toolchain from Maven; tests and the
    // phone check are what gate this app.
    lint { checkReleaseBuilds = false }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    // The segmenter's Silero VAD (silero_vad.onnx): `phone-app` passes a
    // directory holding it; without it the app transcribes whole recordings.
    providers.gradleProperty("vadAssets").orNull?.let { sourceSets.getByName("main").assets.srcDir(it) }
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    // sherpa-onnx (on-phone Parakeet): the release AAR from the Nix store,
    // passed by `phone-app` as -PsherpaAar=<path>.
    providers.gradleProperty("sherpaAar").orNull?.let { implementation(files(it)) }

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.activity.compose)
    implementation(libs.coroutines.android)
    implementation(libs.serialization.json)
    implementation(libs.okhttp)
    // Model archive fallback (tar.bz2).
    implementation(libs.commons.compress)

    testImplementation(libs.junit)
    testImplementation(libs.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)
}
