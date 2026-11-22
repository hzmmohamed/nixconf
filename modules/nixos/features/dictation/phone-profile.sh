# Assembles the phone profile (dictation-server, phone.profile): $base is
# the profile from Nix without localModel.files; this adds one entry per
# Parakeet file of $modelDir (size, sha256, URL under $modelUrl).
# Run by pkgs.runCommand (bash, jq and coreutils on PATH).
# shellcheck disable=SC2154 # base, modelDir, modelFiles, modelUrl, out: derivation env
set -euo pipefail

for f in $modelFiles; do
  p=$modelDir/$f
  jq -n --arg name "$f" --argjson size "$(stat -L -c %s "$p")" \
    --arg sha256 "$(sha256sum "$p" | cut -d' ' -f1)" --arg url "$modelUrl/$f" \
    '{name: $name, size: $size, sha256: $sha256, url: $url}'
done | jq -s --argjson base "$base" '. as $files | $base | .localModel.files = $files' >"$out"
