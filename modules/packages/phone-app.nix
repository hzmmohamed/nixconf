# phone-app: builds the Android companion app (apps/phone/) with nixpkgs'
# Gradle, JDK 17 and an androidenv SDK. Gradle itself fetches AGP, Kotlin and
# AndroidX from Maven/Google (no hermetic APK derivation, by design).
#
#   phone-app build [--release] [--force] [-- <gradle args>]
#   phone-app test [--force] [-- <gradle args>]
#   phone-app install | publish
#
# Release key and passwords live in ~/.config/phone-app/ (never in git);
# `publish` writes into /var/lib/phone-profile/, served by dictation-server.
# The app's default profile URL is that server's (-PprofileUrl, BuildConfig).
# Logic and docs: phone-app.sh next to this file.
{
  lib,
  self,
  ...
}: let
  # The registry host serving the phone profile (dictation-server
  # phone.enable); hosts are evaluated in order only until one matches.
  phoneServer =
    lib.findFirst
    (nixos: nixos.config.preferences.dictation-server.phone.enable or false)
    (throw "phone-app: no host sets preferences.dictation-server.phone.enable")
    (map (name: self.nixosConfigurations.${name})
      (builtins.filter (name: self.nixosConfigurations ? ${name}) (builtins.attrNames self.hosts)));
  profileUrl = "${phoneServer.config.preferences.dictation-server.phone.url}/profile.json";
in {
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
    # as -PsherpaAar. Also runs the segmenter's VAD.
    sherpaAar = pkgs.fetchurl {
      url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.12.38/sherpa-onnx-1.12.38.aar";
      hash = "sha256-elalyZxcHY7XeqdrrZ8PMGhSQS6xF9WP7+BEvYzbGKY=";
    };

    # The segmenter's Silero VAD (the laptops' pin, 2.3 MB), bundled in the
    # APK's assets (-PvadAssets): every session needs it, offline too.
    vadAssets = pkgs.linkFarm "phone-app-assets" [
      {
        name = "silero_vad.onnx";
        path = (self.dictationModels pkgs).sileroVadOnnx;
      }
    ];

    q = lib.escapeShellArg;
  in {
    packages.phone-app = pkgs.writeShellApplication {
      name = "phone-app";
      runtimeInputs = with pkgs; [gradle git coreutils gnused jq];
      text =
        ''
          android_home=${q sdk}
          java_home=${q pkgs.jdk17.home}
          # Maven's aapt2 is linked for an FHS system; use the SDK's.
          aapt2=${q "${sdk}/build-tools/${buildToolsVersion}/aapt2"}
          sherpa_aar=${q sherpaAar}
          vad_assets=${q vadAssets}
          adb=${q "${sdk}/platform-tools/adb"}
          profile_url=${q profileUrl}
        ''
        + builtins.readFile ./phone-app.sh;
    };
  };
}
