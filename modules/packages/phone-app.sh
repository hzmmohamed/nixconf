# phone-app — body of the `phone-app` package (modules/packages/phone-app.nix,
# which prepends android_home, java_home, aapt2, sherpa_aar). Not a standalone
# script. Runs Gradle on apps/phone/ of the repo the current directory is in.

usage() {
  cat >&2 <<EOF
usage: phone-app build [--release] [--force] [-- <gradle args>]
       phone-app test [--force] [-- <gradle args>]
       phone-app install
       phone-app publish

  build     debug APK → apps/phone/app/build/outputs/apk/debug/app-debug.apk
  test      JVM unit tests (testDebugUnitTest)
  --force   run even on a machine that offloads its builds (/etc/nix/machines)
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

run_gradle() {
  export ANDROID_HOME=$android_home ANDROID_SDK_ROOT=$android_home JAVA_HOME=$java_home
  gradle --project-dir "$root/apps/phone" \
    "-Pandroid.aapt2FromMavenOverride=$aapt2" \
    "-PsherpaAar=$sherpa_aar" \
    "$@" "${extra[@]}"
}

case "$cmd" in
  build)
    guard
    [ "$release" = 0 ] || die "build --release: not yet (release signing comes later)"
    run_gradle :app:assembleDebug
    echo "phone-app: $root/apps/phone/app/build/outputs/apk/debug/app-debug.apk"
    ;;
  test)
    guard
    run_gradle :app:testDebugUnitTest
    ;;
  install | publish) die "$cmd: not yet" ;;
  *) usage ;;
esac
