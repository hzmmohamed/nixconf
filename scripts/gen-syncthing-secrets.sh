#!/usr/bin/env bash
set -euo pipefail

# Generate Syncthing key/cert for a host and store them encrypted in sops.
#
# Usage: ./scripts/gen-syncthing-secrets.sh <hostname>
#
# This will:
#   1. Generate a Syncthing key and cert via `syncthing generate`
#   2. Encrypt them into secrets/<hostname>/syncthing.yaml with sops
#
# Requires: syncthing, sops in PATH (available in `nix develop`)

HOSTNAME="${1:?Usage: $0 <hostname>}"

SECRETS_FILE="$(cd "$(dirname "$0")/.." && pwd)/secrets/${HOSTNAME}/syncthing.yaml"

if [[ -f "$SECRETS_FILE" ]]; then
    echo "Error: $SECRETS_FILE already exists. Remove it first if you want to regenerate."
    exit 1
fi

TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "Generating Syncthing key and cert for $HOSTNAME..."
syncthing generate --home "$TMPDIR" 2>/dev/null

KEY="$(cat "$TMPDIR/key.pem")"
CERT="$(cat "$TMPDIR/cert.pem")"

mkdir -p "$(dirname "$SECRETS_FILE")"

# Write plaintext into the final path so sops can match .sops.yaml creation rules,
# then encrypt in-place
cat > "$SECRETS_FILE" <<EOF
syncthing:
    key: |
$(echo "$KEY" | sed 's/^/        /')
    cert: |
$(echo "$CERT" | sed 's/^/        /')
EOF

sops --encrypt --in-place "$SECRETS_FILE"

git -C "$(dirname "$SECRETS_FILE")/../.." add "$SECRETS_FILE"
echo "Encrypted secrets written and staged: $SECRETS_FILE"
