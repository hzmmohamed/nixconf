#!/usr/bin/env bash
set -euo pipefail

# Install NixOS on any host using nixos-anywhere.
#
# Prerequisites:
#   1. Age private key at ~/.config/sops/age/keys.txt
#   2. Target machine booted from NixOS minimal ISO (https://nixos.org/download/#nixos-iso)
#   3. SSH enabled on the live environment (see steps below)
#
# Enabling SSH on the NixOS live ISO:
#   1. Boot the target from the ISO (USB stick / PXE / etc.)
#   2. Once at the shell, set a root password:
#        sudo passwd root
#   3. Find the machine's IP address:
#        ip addr
#      Look for an inet address on the network interface (e.g. enp0s31f6).
#   4. SSH is already running on the minimal ISO. Verify with:
#        systemctl status sshd
#   5. From your workstation, test the connection:
#        ssh root@<ip>
#   6. Run this script:
#        ./scripts/install-host.sh <hostname> <target-ip>
#
# Usage: ./scripts/install-host.sh <hostname> <target-ip> [--cache] [--mount-only] [--luks-password <password>]
#
# Options:
#   --cache              Also serve packages from a local nix-serve cache (port 5000)
#                        on this machine. The target will use it as an extra substituter.
#   --mount-only         Skip partitioning/formatting — just mount existing partitions.
#                        Use this when disks are already set up from a previous attempt.
#   --luks-password <p>  Supply a LUKS password non-interactively. The host's disko.nix
#                        must reference passwordFile = "/tmp/secret.key". If omitted,
#                        disko will prompt interactively.

HOSTNAME="${1:?Usage: $0 <hostname> <target-ip>}"
TARGET_IP="${2:?Usage: $0 <hostname> <target-ip>}"
shift 2

USE_CACHE=false
MOUNT_ONLY=false
LUKS_PASSWORD=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cache) USE_CACHE=true; shift ;;
        --mount-only) MOUNT_ONLY=true; shift ;;
        --luks-password) LUKS_PASSWORD="${2:?--luks-password requires a value}"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

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
mkdir -p "$EXTRA_FILES/home/$USER/.config/sops/age"
cp "$AGE_KEY" "$EXTRA_FILES/home/$USER/.config/sops/age/keys.txt"
chmod 700 "$EXTRA_FILES/home/$USER/.config/sops/age"
chmod 600 "$EXTRA_FILES/home/$USER/.config/sops/age/keys.txt"

echo "Installing $HOSTNAME at $TARGET_IP..."
echo "Building locally, pushing closure to target (no remote substitution)."

NIXOS_ANYWHERE_ARGS=(
    --flake "$FLAKE_DIR#$HOSTNAME"
    --target-host "root@$TARGET_IP"
    --build-on local
    --no-substitute-on-destination
    --extra-files "$EXTRA_FILES"
)

if [[ "$MOUNT_ONLY" == true ]]; then
    echo "Skipping partitioning — mounting existing disks only."
    NIXOS_ANYWHERE_ARGS+=(--disko-mode mount)
fi

if [[ -n "$LUKS_PASSWORD" ]]; then
    LUKS_KEY_FILE="$(mktemp)"
    echo -n "$LUKS_PASSWORD" > "$LUKS_KEY_FILE"
    # Register for cleanup — trap already handles EXTRA_FILES, add this too
    trap 'rm -rf "$EXTRA_FILES" "$LUKS_KEY_FILE"' EXIT
    NIXOS_ANYWHERE_ARGS+=(--disk-encryption-keys /tmp/secret.key "$LUKS_KEY_FILE")
    echo "LUKS password will be supplied non-interactively."
fi

if [[ "$USE_CACHE" == true ]]; then
    # Detect local IP on the interface facing the target
    LOCAL_IP="$(ip route get "$TARGET_IP" | sed -n 's/.*src \([^ ]*\).*/\1/p')"
    if [[ -z "$LOCAL_IP" ]]; then
        echo "Error: Could not determine local IP for reaching $TARGET_IP"
        exit 1
    fi
    CACHE_URL="http://${LOCAL_IP}:5000"
    echo "Using local nix-serve cache at $CACHE_URL"
    # Pass the cache as a nix option so nixos-anywhere uses it when copying the closure
    NIXOS_ANYWHERE_ARGS+=(
        --option extra-substituters "$CACHE_URL"
        --option extra-trusted-substituters "$CACHE_URL"
    )
fi

nix run github:nix-community/nixos-anywhere -- "${NIXOS_ANYWHERE_ARGS[@]}"
