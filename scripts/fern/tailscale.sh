#!/usr/bin/env bash
# Tailscale side of fern (runbook phase 2).
#
#   bash scripts/fern/tailscale.sh store [--dry-run]
#       Hidden prompt for the OAuth client secret (tskey-client-…), checks it
#       against the API, stores it with sops in secrets/shared/tailscale-oauth.yaml
#       (key tailscale_oauth, what features/tailscale.nix reads) and git-adds it.
#       Client: https://login.tailscale.com/admin/settings/oauth
#         scope "Auth Keys" write, tag tag:provisioner only.
#
#   bash scripts/fern/tailscale.sh acl [--apply-acl] [--dry-run]
#       Validates docs/tailscale-policy.hujson (syntax + its `tests`) with the
#       API, backs up the live policy to ~/.local/state/nixconf/, shows the
#       diff and, ONLY with --apply-acl and a y/N, replaces the tailnet policy.
#       Needs a client with the "Policy File" write scope. That secret is asked
#       for at a hidden prompt and NOT stored: the stored host client must stay
#       auth-keys only, or root on any host could rewrite the tailnet ACL.
#
#   bash scripts/fern/tailscale.sh check
#       Tests the stored client: token + granted scopes (mints nothing).
set -euo pipefail
# shellcheck source=scripts/fern/lib.sh
. "$(dirname "$0")/lib.sh"
need jq:jq curl:curl sops:sops -- "$@"

cmd=${1:-}
shift || true
apply_acl=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --apply-acl) apply_acl=1 ;;
    *) die "unknown flag $a" ;;
  esac
done

read_secret() {
  local prompt=$1 var=$2 value
  read -r -s -p "$prompt" value </dev/tty
  echo >&2
  case "$value" in tskey-client-*) ;; *) die "that is not an OAuth client secret (expected tskey-client-…)" ;; esac
  printf -v "$var" '%s' "$value"
}

case "$cmd" in
  store)
    secret=
    read_secret "Paste the OAuth client secret (tskey-client-…, hidden): " secret
    ts_token "$secret" || die "Tailscale rejected the secret"
    log "client OK; granted scopes: ${TS_SCOPES:-?}"
    case " $TS_SCOPES " in
      *auth_keys*) ;;
      *) die "the client lacks the 'auth_keys' scope (Keys → Auth Keys → Write)" ;;
    esac
    case " $TS_SCOPES " in
      *policy_file* | *all*) warn "this client can also rewrite the ACL; a host-wide secret should be auth_keys only (recreate it narrower if you can)" ;;
    esac
    rel=secrets/shared/tailscale-oauth.yaml
    if [ -e "$OAUTH_FILE" ]; then
      current=
      ts_stored_secret current
      if [ "$current" = "$secret" ]; then
        state=unchanged
      else
        log "updating key tailscale_oauth in $rel"
        if [ "$DRY_RUN" = 1 ]; then
          echo "   [dry-run] sops set --value-stdin $rel '[\"tailscale_oauth\"]'" >&2
        else
          printf '"%s"' "$secret" | sops set --value-stdin "$OAUTH_FILE" '["tailscale_oauth"]'
        fi
        state=updated
      fi
    else
      log "creating $rel (encrypted per .sops.yaml)"
      if [ "$DRY_RUN" = 1 ]; then
        echo "   [dry-run] sops encrypt --filename-override $rel > $rel" >&2
      else
        tmp=$(mktemp "$OAUTH_FILE.XXXXXX")
        if ! printf 'tailscale_oauth: %s\n' "$secret" |
          sops encrypt --filename-override "$rel" --input-type yaml --output-type yaml >"$tmp"; then
          rm -f "$tmp"
          die "sops encrypt failed"
        fi
        mv "$tmp" "$OAUTH_FILE"
      fi
      state=created
    fi
    unset secret current
    run git -C "$REPO" add "$rel"
    report_header
    echo "tailscale store: $rel $state; scopes: $TS_SCOPES; dry-run=$DRY_RUN"
    report_footer
    ;;

  check)
    secret=
    ts_stored_secret secret
    ts_token "$secret" || die "the stored client secret no longer works"
    unset secret
    report_header
    echo "tailscale check: stored client OK; scopes: $TS_SCOPES; fern tags: $(fern_tags_json)"
    report_footer
    ;;

  acl)
    policy="$REPO/docs/tailscale-policy.hujson"
    secret=
    read_secret "Paste a client secret with the Policy File scope (hidden, not stored): " secret
    ts_token "$secret" || die "Tailscale rejected the secret"
    unset secret
    token=$TS_TOKEN

    log "validating $(basename "$policy") (syntax + tests)"
    resp=$(ts_api "$token" -H 'Content-Type: application/hujson' --data-binary @"$policy" \
      "$TS_API/tailnet/-/acl/validate") || die "validate call failed: $resp"
    if [ "$(printf '%s' "$resp" | jq -r '.message // ""')" != "" ]; then
      printf '%s\n' "$resp" | jq . >&2
      die "the policy does not validate; nothing applied"
    fi
    log "valid, tests pass"

    state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/nixconf
    mkdir -p "$state_dir"
    backup="$state_dir/tailscale-acl-$(date +%Y%m%dT%H%M%S).hujson"
    headers=$(mktemp)
    ts_api "$token" -H 'Accept: application/hujson' -D "$headers" "$TS_API/tailnet/-/acl" >"$backup" ||
      die "could not read the live policy"
    etag=$(sed -n 's/^[Ee][Tt]ag: *//p' "$headers" | tr -d '\r')
    rm -f "$headers"
    log "live policy backed up to $backup"
    diff -u "$backup" "$policy" | head -n 200 || true

    applied=no
    if [ "$apply_acl" = 1 ]; then
      if [ "$DRY_RUN" = 1 ]; then
        echo "   [dry-run] POST $TS_API/tailnet/-/acl (If-Match: etag)" >&2
      elif confirm "Replace the tailnet policy with docs/tailscale-policy.hujson?"; then
        ts_api "$token" -H 'Content-Type: application/hujson' -H "If-Match: $etag" \
          --data-binary @"$policy" "$TS_API/tailnet/-/acl" >/dev/null ||
          die "apply failed (someone edited the policy meanwhile? re-run)"
        applied=yes
      fi
    else
      log "validate only; re-run with --apply-acl to replace the live policy"
    fi
    report_header
    echo "tailscale acl: valid=yes applied=$applied backup=$backup dry-run=$DRY_RUN"
    report_footer
    ;;

  *)
    echo "usage: tailscale.sh store|check|acl [--apply-acl] [--dry-run]" >&2
    exit 2
    ;;
esac
