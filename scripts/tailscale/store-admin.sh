#!/usr/bin/env bash
# Store the tailnet ADMIN OAuth client (the OpenTofu provider credential).
#   bash scripts/tailscale/store-admin.sh [--dry-run]
#
# Hidden prompt for the secret (tskey-client-…), checks it against the API
# and its scopes, and stores it with sops in secrets/admin/tailscale-admin.yaml
# (key tailscale_admin_oauth), encrypted ONLY to the primary age key
# (.sops.yaml rule secrets/admin/…). No host can decrypt it. git-adds it.
#
# Client: https://login.tailscale.com/admin/settings/oauth, description
# "nixconf admin (tofu)", write scopes: Policy File, DNS, Feature Settings,
# Networking Settings, Devices Core, Auth Keys, OAuth Keys; tag
# tag:provisioner (Devices Core / Auth Keys require a tag).
set -euo pipefail
# shellcheck source=scripts/tailscale/lib.sh
. "$(dirname "$0")/lib.sh"
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    *) die "unknown flag $a" ;;
  esac
done
need jq:jq curl:curl sops:sops -- "$@"

grep -q 'secrets/admin/' "$REPO/.sops.yaml" ||
  die ".sops.yaml has no secrets/admin/ rule; refusing (it would fall to the catch-all)"

secret=
read -r -s -p "Paste the ADMIN OAuth client secret (tskey-client-…, hidden): " secret </dev/tty
echo >&2
case "$secret" in tskey-client-*) ;; *) die "that is not an OAuth client secret (expected tskey-client-…)" ;; esac
ts_token "$secret" || die "Tailscale rejected the secret"
unset TS_TOKEN
log "client OK; granted scopes: ${TS_SCOPES:-?}"
lacking=
for s in $REQUIRED_SCOPES; do has_scope "$s" || lacking="$lacking $s"; done
[ -z "$lacking" ] || die "missing required write scope(s):$lacking; edit the client and re-run"
absent=
for s in $OPTIONAL_SCOPES; do has_scope "$s" || absent="$absent $s"; done
[ -z "$absent" ] || warn "optional scope(s) absent:$absent (that part stays unmanaged; see the doc)"

mkdir -p "$(dirname "$ADMIN_FILE")"
if [ -e "$ADMIN_FILE" ]; then
  current=$(sops decrypt --extract "[\"$ADMIN_KEY\"]" "$ADMIN_FILE" 2>/dev/null || true)
  if [ "$current" = "$secret" ]; then
    state=unchanged
  else
    log "updating key $ADMIN_KEY in $ADMIN_REL"
    if [ "$DRY_RUN" = 1 ]; then
      echo "   [dry-run] sops set --value-stdin $ADMIN_REL '[\"$ADMIN_KEY\"]'" >&2
    else
      printf '"%s"' "$secret" | sops set --value-stdin "$ADMIN_FILE" "[\"$ADMIN_KEY\"]"
    fi
    state=updated
  fi
else
  log "creating $ADMIN_REL (encrypted per .sops.yaml: primary key only)"
  if [ "$DRY_RUN" = 1 ]; then
    echo "   [dry-run] sops encrypt --filename-override $ADMIN_REL > $ADMIN_REL" >&2
  else
    tmp=$(mktemp "$ADMIN_FILE.XXXXXX")
    if ! printf '%s: %s\n' "$ADMIN_KEY" "$secret" |
      sops encrypt --filename-override "$ADMIN_REL" --input-type yaml --output-type yaml >"$tmp"; then
      rm -f "$tmp"
      die "sops encrypt failed"
    fi
    mv "$tmp" "$ADMIN_FILE"
  fi
  state=created
fi
unset secret current

recipients=dry-run
if [ "$DRY_RUN" != 1 ]; then
  recipients=$(grep -c '^ *- recipient: age1' "$ADMIN_FILE" || true)
  run git -C "$REPO" add "$ADMIN_REL"
fi

report_header
echo "tailnet store-admin: $ADMIN_REL $state; age recipients=$recipients (expect 1); scopes: $TS_SCOPES; dry-run=$DRY_RUN"
report_footer
