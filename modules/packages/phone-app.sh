# phone-app — body of the `phone-app` package (modules/packages/phone-app.nix,
# which prepends android_home, java_home, aapt2, sherpa_aar, vad_assets, adb). Not a
# standalone script. Runs Gradle on apps/phone/ of the repo the current
# directory is in.

# Served by dictation-server's phone profile (preferences.dictation-server.phone).
state=/var/lib/phone-profile

usage() {
  cat >&2 <<EOF
usage: phone-app build [--release] [--force] [-- <gradle args>]
       phone-app test [--force] [-- <gradle args>]
       phone-app install
       phone-app publish

  build      debug APK → apps/phone/app/build/outputs/apk/debug/app-debug.apk
  --release  signed with ~/.config/phone-app/release.jks → …/apk/release/app-release.apk
  test       JVM unit tests (testDebugUnitTest)
  install    adb install -r the release APK (else the debug one) to the phone on USB
  publish    copy the release APK to $state/app/ and point app.json at it
             (the in-app update picks it up; no redeploy)
  --force    run even on a machine that offloads its builds (/etc/nix/machines)
EOF
  exit 2
}
die() {
  echo "phone-app: $*" >&2
  exit 1
}

[ $# -ge 1 ] || usage
cmd=$1
shift

release=0
force=0
extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    --release) release=1 ;;
    --force) force=1 ;;
    --)
      shift
      extra=("$@")
      break
      ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
  shift
done

# The Android SDK, Gradle caches and builds are big: keep them off machines
# whose nix daemon offloads to a builder (hazel).
guard() {
  if [ "$force" = 0 ] && [ -s /etc/nix/machines ]; then
    echo "phone-app: this machine offloads its builds; run on the builder or pass --force" >&2
    exit 2
  fi
}

root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside the nixconf repo"
[ -f "$root/apps/phone/settings.gradle.kts" ] || die "$root/apps/phone is not the phone app"
apks=$root/apps/phone/app/build/outputs/apk
release_apk=$apks/release/app-release.apk
debug_apk=$apks/debug/app-debug.apk

# Signing inputs, outside git (back them up in the vault: a lost key means
# uninstalling the app, and its drafts, to install a new one).
signing_dir=$HOME/.config/phone-app
keystore=$signing_dir/release.jks
signing_props=$signing_dir/signing.properties

run_gradle() {
  export ANDROID_HOME=$android_home ANDROID_SDK_ROOT=$android_home JAVA_HOME=$java_home
  gradle --project-dir "$root/apps/phone" \
    "-Pandroid.aapt2FromMavenOverride=$aapt2" \
    "-PsherpaAar=$sherpa_aar" \
    "-PvadAssets=$vad_assets" \
    "-PprofileUrl=$profile_url" \
    "$@" "${extra[@]}"
}

# versionCode = commit count, versionName = short rev (+ -dirty).
version_args() {
  local code name
  code=$(git -C "$root" rev-list --count HEAD)
  name=$(git -C "$root" rev-parse --short HEAD)
  [ -z "$(git -C "$root" status --porcelain)" ] || name=$name-dirty
  echo "-PversionCode=$code" "-PversionName=$name"
}

need_signing() {
  [ -f "$keystore" ] && [ -f "$signing_props" ] && return
  cat >&2 <<EOF
phone-app: build --release needs the release key, kept outside git:
  $keystore
  $signing_props
Create them once (keytool is in the JDK: $java_home/bin/keytool):

  mkdir -p ~/.config/phone-app
  keytool -genkeypair -v -keystore ~/.config/phone-app/release.jks -keyalg RSA -keysize 4096 -validity 36500 -alias nixconf-phone
  printf '%s\n' 'storePassword=<store password>' 'keyAlias=nixconf-phone' 'keyPassword=<key password>' > ~/.config/phone-app/signing.properties
  chmod 600 ~/.config/phone-app/signing.properties

and back both files up in the vault.
EOF
  exit 1
}

case "$cmd" in
  build)
    [ "$release" = 0 ] || need_signing
    guard
    # shellcheck disable=SC2046 # two words on purpose
    if [ "$release" = 1 ]; then
      run_gradle :app:assembleRelease $(version_args) \
        "-PreleaseStoreFile=$keystore" "-PsigningProperties=$signing_props"
      [ -f "$release_apk" ] || die "no $release_apk (unsigned build?)"
      echo "phone-app: $release_apk"
    else
      run_gradle :app:assembleDebug $(version_args)
      echo "phone-app: $debug_apk"
    fi
    ;;
  test)
    guard
    run_gradle :app:testDebugUnitTest
    ;;
  install)
    apk=$release_apk
    [ -f "$apk" ] || apk=$debug_apk
    [ -f "$apk" ] || die "no APK yet: run 'phone-app build' first"
    echo "phone-app: installing $apk"
    "$adb" install -r "$apk" ||
      die "adb install failed; a build signed with another key needs 'adb uninstall nixconf.phone' first (that deletes the app's drafts)"
    ;;
  publish)
    [ -f "$release_apk" ] || die "no release APK: run 'phone-app build --release' first"
    [ -d "$state" ] ||
      die "$state does not exist: deploy dictation-server with preferences.dictation-server.phone.enable = true on this host first"
    [ -w "$state" ] && [ -d "$state/app" ] && [ -w "$state/app" ] ||
      die "$state and $state/app must be writable by $(id -un) (set up by dictation-server's phone profile)"
    app_url=$(jq -er '.appUrl' "$state/profile.json") || die "no appUrl in $state/profile.json"
    base=${app_url%/*}

    badging=$("$aapt2" dump badging "$release_apk") || die "cannot read $release_apk"
    code=$(sed -n "s/^package: .* versionCode='\([0-9]*\)'.*/\1/p" <<<"$badging")
    vname=$(sed -n "s/^package: .* versionName='\([^']*\)'.*/\1/p" <<<"$badging")
    [ -n "$code" ] || die "no versionCode in $release_apk"
    if old=$(jq -e '.versionCode' "$state/app.json" 2>/dev/null) && [ "$old" -ge "$code" ]; then
      echo "phone-app: warning: published versionCode $old >= $code; phones will not offer this build" >&2
    fi

    name=nixconf-phone-$code.apk
    sha=$(sha256sum "$release_apk" | cut -d' ' -f1)
    cp "$release_apk" "$state/app/.$name.tmp"
    mv -f "$state/app/.$name.tmp" "$state/app/$name"
    jq -n --argjson versionCode "$code" --arg versionName "$vname" \
      --arg url "$base/app/$name" --arg sha256 "$sha" \
      '{versionCode: $versionCode, versionName: $versionName, url: $url, sha256: $sha256}' \
      >"$state/.app.json.tmp"
    mv -f "$state/.app.json.tmp" "$state/app.json"

    # Keep the last 3 APKs.
    for f in "$state"/app/nixconf-phone-*.apk; do
      if [ -e "$f" ]; then basename "$f"; fi
    done | sort -t- -k3 -n | head -n -3 | while read -r stale; do
      rm -f "$state/app/$stale"
    done
    echo "phone-app: published $vname ($code) as $base/app/$name"
    ;;
  *) usage ;;
esac
