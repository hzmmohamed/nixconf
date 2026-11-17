#!/usr/bin/env bash
# Enrol fern after its first boot (runbook phase 4).
#   bash scripts/fern/enroll.sh [--dry-run] [--ip 100.x.y.z] [--host-key 'ssh-ed25519 …']
#
#  1. waits (≤ 20 min) for fern to come online in the tailnet (local tailscaled)
#  2. reads its tailnet IPv4 and its SSH host key (ssh-keyscan on port 7654
#     over the tailnet), checks that your key logs in and the boot mode
#  3. edits modules/hosts-registry.nix (ts4, hostKey) and .sops.yaml (&fern,
#     `- *fern`) at the `# fern-*` anchors (scripts/fern/edit-anchors.py)
#  4. `sops updatekeys -y` on every sops file fern's config references
#  5. git add, eval fern, print the deploy command
# Tailscale has no API to pin a node's IP; it stays stable while the node is
# not re-registered (pin it in the admin console if you want: Machines → fern → Edit IPv4).
# --dry-run: steps 1–2 (or the --ip/--host-key overrides), then show the diff
# of step 3 on temporary copies. Writes nothing, re-encrypts nothing.
set -euo pipefail
# shellcheck source=scripts/fern/lib.sh
. "$(dirname "$0")/lib.sh"
need jq:jq python3:python3 ssh-to-age:ssh-to-age sops:sops -- "$@"

ip=
host_key=
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --ip)
      ip=$2
      shift
      ;;
    --host-key)
      host_key=$2
      shift
      ;;
    *) die "unknown argument $1" ;;
  esac
  shift
done
user=$(nix eval --raw "$REPO#user.name" 2>/dev/null || id -un)
domain=$(nix eval --raw "$REPO#tailnet.domain")

# 1. Tailnet.
if [ -z "$ip" ]; then
  log "waiting for $NAME to come online in the tailnet (≤ 20 min; first boot rebuilds the bootstrap config)"
  for i in $(seq 80); do
    line=$(ts_peer | awk '$2 == "true"' | head -n1 || true)
    [ -n "$line" ] && break
    [ $((i % 4)) = 0 ] && log "  still waiting ($((i / 4)) min)"
    sleep 15
  done
  [ -n "${line:-}" ] || die "$NAME did not come online. Console: aws ec2 get-console-output --region $REGION --instance-id \$(cd infra/aws && tofu output -raw instance_id) --latest --output text | tail -50"
  read -r ip _ dns <<<"$line"
  log "$NAME is online at $ip ($dns)"
  [ "$dns" = "$NAME.$domain." ] || warn "MagicDNS name is $dns, not $NAME.$domain (a stale node took the name; remove it and rename this one)"
fi

# 2. Host key + login test.
if [ -z "$host_key" ]; then
  log "reading the SSH host key on $ip:$SSH_PORT"
  for _ in $(seq 20); do
    host_key=$(ssh-keyscan -T 5 -p "$SSH_PORT" -t ed25519 "$ip" 2>/dev/null | awk '{print $2 " " $3}' | head -n1)
    [ -n "$host_key" ] && break
    sleep 15
  done
  [ -n "$host_key" ] || die "no sshd on $ip:$SSH_PORT yet"
fi
kh=$(mktemp)
trap 'rm -f "$kh"' EXIT
printf '[%s]:%s %s\n' "$ip" "$SSH_PORT" "$host_key" >"$kh"
boot=unknown
if [ "$DRY_RUN" = 0 ] || ssh-keyscan -T 3 -p "$SSH_PORT" "$ip" >/dev/null 2>&1; then
  if boot=$(ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 -o UserKnownHostsFile="$kh" \
    -o StrictHostKeyChecking=yes "$user@$ip" 'test -d /sys/firmware/efi && echo efi || echo bios' 2>/dev/null); then
    log "login as $user OK; boot mode: $boot"
    [ "$boot" = bios ] || warn "fern booted UEFI: set ec2.efi = true in modules/nixos/hosts/fern before deploying"
  else
    [ "$DRY_RUN" = 1 ] || die "cannot log in as $user@$ip:$SSH_PORT with your key (is it in ssh_public_keys?)"
  fi
fi
age=$(printf '%s\n' "$host_key" | ssh-to-age)
log "fern's age recipient: $age"

# 3. Edits at the anchors.
if [ "$DRY_RUN" = 1 ]; then
  tmp=$(mktemp -d)
  mkdir -p "$tmp/modules"
  cp "$REPO/modules/hosts-registry.nix" "$tmp/modules/"
  cp "$REPO/.sops.yaml" "$tmp/"
  python3 "$REPO/scripts/fern/edit-anchors.py" "$tmp" "$ip" "$host_key" "$age"
  diff -u "$REPO/modules/hosts-registry.nix" "$tmp/modules/hosts-registry.nix" || true
  diff -u "$REPO/.sops.yaml" "$tmp/.sops.yaml" || true
  rm -f "$tmp/modules/hosts-registry.nix" "$tmp/.sops.yaml"
  rmdir "$tmp/modules" "$tmp"
else
  python3 "$REPO/scripts/fern/edit-anchors.py" "$REPO" "$ip" "$host_key" "$age"
fi

# 4. Re-encrypt what fern decrypts (derived from its config, so new secrets
#    are picked up). Files outside the fern rules in .sops.yaml are reported.
mapfile -t files < <(nix eval --json "$REPO#nixosConfigurations.$NAME.config.sops.secrets" \
  --apply 'ss: builtins.attrValues (builtins.mapAttrs (_: v: toString v.sopsFile) ss)' |
  jq -r '.[]' | sed -E 's|^/nix/store/[^/]+-source/||' | sort -u)
for f in secrets/fern/*.yaml; do [ -e "$REPO/$f" ] && files+=("$f"); done
mapfile -t files < <(printf '%s\n' "${files[@]}" | sort -u)
updated=()
missing=()
for f in "${files[@]}"; do
  [ -e "$REPO/$f" ] || continue
  if [ "$DRY_RUN" = 1 ]; then
    echo "   [dry-run] sops updatekeys -y $f" >&2
    continue
  fi
  (cd "$REPO" && sops updatekeys -y "$f" >/dev/null 2>&1) || die "sops updatekeys $f failed"
  if grep -q "$age" "$REPO/$f"; then updated+=("$f"); else missing+=("$f"); fi
done

# 5. Stage + eval.
if [ "$DRY_RUN" = 0 ]; then
  git -C "$REPO" add modules/hosts-registry.nix .sops.yaml "${files[@]}"
  drv=$(nix eval --raw "$REPO#nixosConfigurations.$NAME.config.system.build.toplevel.drvPath") || die "fern does not evaluate"
fi

report_header
echo "enroll: ip=$ip boot=$boot dry-run=$DRY_RUN"
echo "host key: $host_key"
echo "age: $age"
echo "re-encrypted for fern: ${updated[*]:-none}"
[ ${#missing[@]} -eq 0 ] || echo "NOT covered by a fern rule in .sops.yaml (agent: extend the rule): ${missing[*]}"
[ "$DRY_RUN" = 1 ] || echo "eval: OK ${drv##*/}"
echo "next: env DEPLOY_TARGET=$ip just deploy $NAME"
report_footer
