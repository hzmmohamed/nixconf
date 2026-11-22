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
        versionCode = 1
        versionName = "dev"
        ndk { abiFilters += "arm64-v8a" }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures { compose = true }
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

    testImplementation(libs.junit)
    testImplementation(libs.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)
}
