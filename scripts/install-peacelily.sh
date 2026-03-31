#!/usr/bin/env bash
set -euo pipefail

# Install NixOS on peacelily using nixos-anywhere.
#
# Prerequisites:
#   1. Age private key at ~/.config/sops/age/keys.txt
#   2. Peacelily booted from NixOS minimal ISO (https://nixos.org/download/#nixos-iso)
#   3. SSH enabled on the live environment (see steps below)
#
# Enabling SSH on the NixOS live ISO:
#   1. Boot peacelily from the ISO (USB stick / PXE / etc.)
#   2. Once at the shell, set a password for root:
#        passwd
#   3. Find the machine's IP address:
#        ip addr
#      Look for an inet address on the wired interface (e.g. enp0s31f6).
#   4. SSH is already running on the minimal ISO. Verify with:
#        systemctl status sshd
#   5. From your workstation, test the connection:
#        ssh root@<ip>
#   6. Run this script:
#        ./scripts/install-peacelily.sh <ip>
#
# Usage: ./scripts/install-peacelily.sh <target-ip>

TARGET_IP="${1:?Usage: $0 <target-ip>}"
FLAKE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGE_KEY="$HOME/.config/sops/age/keys.txt"
EXTRA_FILES="$(mktemp -d)"

cleanup() {
    rm -rf "$EXTRA_FILES"
}
trap cleanup EXIT

# Verify age key exists
if [[ ! -f "$AGE_KEY" ]]; then
    echo "Error: Age key not found at $AGE_KEY"
    echo "sops-nix needs this key to decrypt secrets during installation."
    exit 1
fi

# Prepare extra files: age key for sops-nix
mkdir -p "$EXTRA_FILES/home/hfahmi/.config/sops/age"
cp "$AGE_KEY" "$EXTRA_FILES/home/hfahmi/.config/sops/age/keys.txt"
chmod 700 "$EXTRA_FILES/home/hfahmi/.config/sops/age"
chmod 600 "$EXTRA_FILES/home/hfahmi/.config/sops/age/keys.txt"

echo "Installing peacelily at $TARGET_IP..."
echo "Building locally, installing remotely via nixos-anywhere."

nix run github:nix-community/nixos-anywhere -- \
    --flake "$FLAKE_DIR#peacelily" \
    --target-host "root@$TARGET_IP" \
    --build-on local \
    --extra-files "$EXTRA_FILES"
