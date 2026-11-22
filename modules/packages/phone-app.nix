# phone-app: builds the Android companion app (apps/phone/) with nixpkgs'
# Gradle, JDK 17 and an androidenv SDK. Gradle itself fetches AGP, Kotlin and
# AndroidX from Maven/Google (no hermetic APK derivation, by design).
#
#   phone-app build [--release] [--force] [-- <gradle args>]
#   phone-app test [--force] [-- <gradle args>]
#   phone-app install | publish
#
# Logic and docs: phone-app.sh next to this file.
{lib, ...}: {
  perSystem = {pkgs, ...}: let
    buildToolsVersion = "36.0.0";
    android = pkgs.androidenv.composeAndroidPackages {
      platformVersions = ["36"];
      buildToolsVersions = [buildToolsVersion];
      includeNDK = false;
      includeEmulator = false;
    };
    sdk = "${android.androidsdk}/libexec/android-sdk";

    # On-phone Parakeet runtime (classes.jar + jni/arm64-v8a); handed to Gradle
    # as -PsherpaAar.
    sherpaAar = pkgs.fetchurl {
      url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.12.38/sherpa-onnx-1.12.38.aar";
      hash = "sha256-elalyZxcHY7XeqdrrZ8PMGhSQS6xF9WP7+BEvYzbGKY=";
    };

    q = lib.escapeShellArg;
  in {
    packages.phone-app = pkgs.writeShellApplication {
      name = "phone-app";
      runtimeInputs = with pkgs; [gradle git coreutils];
      text =
        ''
          android_home=${q sdk}
          java_home=${q pkgs.jdk17.home}
          # Maven's aapt2 is linked for an FHS system; use the SDK's.
          aapt2=${q "${sdk}/build-tools/${buildToolsVersion}/aapt2"}
          sherpa_aar=${q sherpaAar}
        ''
        + builtins.readFile ./phone-app.sh;
    };
  };
}
