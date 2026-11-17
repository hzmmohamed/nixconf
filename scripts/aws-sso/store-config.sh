#!/usr/bin/env bash
# Store the SSO client settings in sops: secrets/shared/aws-sso.yaml
#   bash scripts/aws-sso/store-config.sh [--dry-run]
#
# Keys: account_id, start_url, region. They are not credentials, but the repo
# is public, so they stay encrypted. features/aws.nix renders ~/.aws/config
# from them (profiles tfc-admin / tfc-operator / tfc-cloudbox, sso-session
# tfc) on butternut and hazel. Encrypted per the .sops.yaml rule for this file
# (primary key; never fern). Looked up live with the current admin
# credentials; AWS_SSO_START_URL overrides the start URL when the access
# portal has a customised subdomain. git-adds the file.
set -euo pipefail
# shellcheck source=scripts/aws-sso/lib.sh
. "$(dirname "$0")/lib.sh"
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    *) die "unknown flag $a" ;;
  esac
done
need awscli2:aws jq:jq sops:sops curl:curl -- "$@"

grep -q 'secrets/shared/aws-sso' "$REPO/.sops.yaml" ||
  die ".sops.yaml has no rule for $CONFIG_REL; refusing (it would fall to the catch-all)"

discover
[ "$IC_STATE" = ACTIVE ] || die "Identity Center is not active (run setup.sh first)"
start_url=${AWS_SSO_START_URL:-https://$IDENTITY_STORE.awsapps.com/start}
case "$start_url" in https://*) ;; *) die "AWS_SSO_START_URL must be an https:// URL" ;; esac

# Reachability check of the portal (no credentials involved).
portal=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$start_url" || echo 000)

declare -A want=([account_id]="$ACCOUNT_ID" [start_url]="$start_url" [region]="$SSO_REGION")
state=
if [ -e "$CONFIG_FILE" ]; then
  for k in account_id start_url region; do
    cur=$(sops decrypt --extract "[\"$k\"]" "$CONFIG_FILE" 2>/dev/null || true)
    [ "$cur" = "${want[$k]}" ] && continue
    log "updating $k in $CONFIG_REL"
    if [ "$DRY_RUN" = 1 ]; then
      echo "   [dry-run] sops set $CONFIG_REL '[\"$k\"]'" >&2
    else
      printf '"%s"' "${want[$k]}" | sops set --value-stdin "$CONFIG_FILE" "[\"$k\"]"
    fi
    state="$state $k"
  done
  state=${state:+updated:$state}
  state=${state:-unchanged}
else
  log "creating $CONFIG_REL"
  if [ "$DRY_RUN" = 1 ]; then
    echo "   [dry-run] sops encrypt --filename-override $CONFIG_REL > $CONFIG_REL" >&2
  else
    tmp=$(mktemp "$CONFIG_FILE.XXXXXX")
    if ! printf 'account_id: "%s"\nstart_url: "%s"\nregion: "%s"\n' \
      "${want[account_id]}" "${want[start_url]}" "${want[region]}" |
      sops encrypt --filename-override "$CONFIG_REL" --input-type yaml --output-type yaml >"$tmp"; then
      rm -f "$tmp"
      die "sops encrypt failed"
    fi
    mv "$tmp" "$CONFIG_FILE"
  fi
  state=created
fi

recipients=dry-run
if [ "$DRY_RUN" != 1 ]; then
  recipients=$(grep -cE '^ *-? *recipient: age1' "$CONFIG_FILE" || true)
  run git -C "$REPO" add "$CONFIG_REL"
fi

report_header
echo "aws-sso store-config: $CONFIG_REL $state; age recipients=$recipients (expect 1: primary); dry-run=$DRY_RUN"
echo "  region=$SSO_REGION start-url=$(printf "%s" "$start_url" | sed -E "s#https://[^/]+#https://<portal-host>#") (override=${AWS_SSO_START_URL:+yes}) portal-http=$portal"
report_footer
