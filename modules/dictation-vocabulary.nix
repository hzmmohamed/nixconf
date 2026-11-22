# Fleet-wide dictation vocabulary: flake-level data, read as
# `self.dictationVocabulary`. Feeds the Whisper initial prompt (names and
# spellings Whisper would otherwise guess) of the desktop `dictate` clients
# and of the phone profile (dictation-server). Hosts may extend it locally.
{...}: {
  flake.dictationVocabulary = [
    "NixOS"
    "Nix"
    "flake"
    "home-manager"
    "Sway"
    "Claude Code"
    "T3 Code"
    "Tailscale"
    "Syncthing"
    "KeePassXC"
    "hazel"
    "butternut"
    "maple"
    "peacelily"
    "fern"
    "routelab"
    "QGIS"
    "Parakeet"
    "Whisper"
  ];
}
