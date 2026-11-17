#!/usr/bin/env bash
# ssh to fern by the registry's tailnet IP and port, before this machine has
# been switched to a config whose ssh_config/known_hosts know fern.
#   bash scripts/fern/ssh.sh [command…]     e.g. bash scripts/fern/ssh.sh claude
set -euo pipefail
# shellcheck source=scripts/fern/lib.sh
. "$(dirname "$0")/lib.sh"
user=$(nix eval --raw "$REPO#user.name")
ip=$(nix eval --raw "$REPO#hosts.$NAME.ts4" 2>/dev/null) || die "fern has no ts4 in the registry yet (phase 4)"
key=$(nix eval --raw "$REPO#hosts.$NAME.hostKey" 2>/dev/null) || die "fern has no hostKey in the registry yet (phase 4)"
kh=$(mktemp)
trap 'rm -f "$kh"' EXIT
printf '[%s]:%s %s\n' "$ip" "$SSH_PORT" "$key" >"$kh"
# Not exec: the trap must remove the temp known_hosts afterwards.
ssh -t -p "$SSH_PORT" -o UserKnownHostsFile="$kh" -o StrictHostKeyChecking=yes "$user@$ip" "$@"
