#!/usr/bin/env bash
# Apply the tailnet plan after a y/N.
#   bash scripts/tailscale/apply.sh
#   env TAILNET_DEVICE_TAGS=1 bash scripts/tailscale/apply.sh
#
# Same preparation as plan.sh, then plan -out, the summary, y/N, and an
# apply of exactly that plan (imports land in state here). If tofu created
# or replaced the hosts OAuth client, its new secret is piped straight from
# `tofu output` into `sops set` on secrets/shared/tailscale-oauth.yaml
# (never printed) and git-added.
set -euo pipefail
# shellcheck source=scripts/tailscale/lib.sh
. "$(dirname "$0")/lib.sh"
for a in "$@"; do die "unknown flag $a"; done
prepare "$@"
make_plan

echo
echo "---- plan summary ----"
plan_report
echo "----------------------"

applied=no
hosts_secret_state=untouched
if [ "$PLAN_RC" = 0 ]; then
  log "no changes"
elif confirm "Apply this plan to the tailnet?"; then
  tf apply -input=false -no-color "$PLAN_FILE"
  applied=yes

  new=$(tf output -raw hosts_oauth_client_secret 2>/dev/null || true)
  if [ -n "$new" ]; then
    current=
    [ -e "$OAUTH_FILE" ] && current=$(sops decrypt --extract '["tailscale_oauth"]' "$OAUTH_FILE")
    if [ "$new" = "$current" ]; then
      hosts_secret_state=unchanged
    elif [ -e "$OAUTH_FILE" ]; then
      printf '"%s"' "$new" | sops set --value-stdin "$OAUTH_FILE" '["tailscale_oauth"]'
      hosts_secret_state=rotated
    else
      tmp=$(mktemp "$OAUTH_FILE.XXXXXX")
      printf 'tailscale_oauth: %s\n' "$new" |
        sops encrypt --filename-override secrets/shared/tailscale-oauth.yaml \
          --input-type yaml --output-type yaml >"$tmp" || {
        rm -f "$tmp"
        die "sops encrypt failed; the new secret is only in the tofu state now"
      }
      mv "$tmp" "$OAUTH_FILE"
      hosts_secret_state=created
    fi
    unset new current
    [ "$hosts_secret_state" = unchanged ] || run git -C "$REPO" add secrets/shared/tailscale-oauth.yaml
  fi
fi

report_header
echo "tailnet apply: applied=$applied hosts-client-secret=$hosts_secret_state"
echo "  managed: acl=yes dns=yes settings=$MANAGE_SETTINGS hosts-client=$MANAGE_HOSTS_CLIENT devices=$MANAGE_DEVICES"
if [ "$applied" = yes ]; then
  echo "  state: $(tf state list | tr '\n' ' ')"
  echo "  managed devices: $(tf output -json managed_devices 2>/dev/null | jq -r 'join(",")')"
fi
report_footer
