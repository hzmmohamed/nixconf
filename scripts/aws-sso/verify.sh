#!/usr/bin/env bash
# Verify the SSO client side after the rebuild (read-only, no AWS writes).
#   aws-login                                  # once: browser / device code
#   bash scripts/aws-sso/verify.sh
#
# Checks the managed block in ~/.aws/config, then per profile: who it is, one
# thing it must be able to do and one thing it must NOT be able to do. Also
# shows the secretspec user config. Runbook: docs/plans/2026-11-17-aws-sso-runbook.md
set -euo pipefail
# shellcheck source=scripts/aws-sso/lib.sh
. "$(dirname "$0")/lib.sh"
need awscli2:aws jq:jq -- "$@"

ok() { printf 'ok'; }
# `try <profile> args…`: ok | denied | expired | error
try() {
  local p=$1 out
  shift
  if out=$(AWS_PROFILE=$p aws --region "$REGION" "$@" 2>&1 >/dev/null); then
    ok
  else
    case "$out" in
      *AccessDenied* | *UnauthorizedOperation* | *"not authorized"*) printf 'denied' ;;
      *SSO* | *[Tt]oken*) printf 'expired' ;;
      *) printf 'error' ;;
    esac
  fi
}
whoami_() {
  AWS_PROFILE=$1 aws sts get-caller-identity --query Arn --output text 2>/dev/null |
    sed -E 's#.*assumed-role/AWSReservedSSO_([^_]+)_[^/]*/(.*)#\1 as \2#' | mask || echo "no session"
}

block=no
grep -q '^# BEGIN nixconf aws-sso' "$HOME/.aws/config" 2>/dev/null && block=yes
profiles=$(aws configure list-profiles 2>/dev/null | tr '\n' ' ')
token=none
for f in "$HOME"/.aws/sso/cache/*.json; do
  [ -e "$f" ] || continue
  exp=$(jq -r 'select(.startUrl != null and .accessToken != null) | .expiresAt // empty' "$f" 2>/dev/null || true)
  [ -n "$exp" ] && token="expires $exp"
done

scratch=$(tfvar scratch_bucket_name 2>/dev/null || true)
prefix=$(tfvar scratch_prefix 2>/dev/null || true)

report_header
echo "aws-sso verify on $(uname -n): managed-block=$block sso-token=$token"
echo "  profiles: $profiles"
echo "  tfc-admin:    $(whoami_ tfc-admin); iam list-roles=$(try tfc-admin iam list-roles --max-items 1)"
echo "  tfc-cloudbox: $(whoami_ tfc-cloudbox); describe $NAME=$(try tfc-cloudbox ec2 describe-instances --filters "Name=tag:Name,Values=$NAME")" \
  "s3 ls (expect denied)=$(try tfc-cloudbox s3api list-buckets)"
if [ -n "$scratch" ]; then
  echo "  tfc-operator: $(whoami_ tfc-operator); ls scratch=$(try tfc-operator s3 ls "s3://$scratch/$prefix")" \
    "run-config=$(try tfc-operator ssm get-parameter --name "/cairo-sim/$CAIRO_SIM_STAGE/run-config")" \
    "iam list-roles (expect denied)=$(try tfc-operator iam list-roles --max-items 1)"
else
  echo "  tfc-operator: $(whoami_ tfc-operator); (no infra/aws/fern.auto.tfvars here: bucket checks skipped)" \
    "run-config=$(try tfc-operator ssm get-parameter --name "/cairo-sim/$CAIRO_SIM_STAGE/run-config")" \
    "iam list-roles (expect denied)=$(try tfc-operator iam list-roles --max-items 1)"
fi
echo "  default (static keys, untouched): $(aws sts get-caller-identity --profile default --query Arn --output text 2>/dev/null | mask || echo none)"
if command -v secretspec >/dev/null 2>&1; then
  echo "  secretspec $(secretspec --version 2>/dev/null | awk '{print $2}'): $(tr '\n' ' ' <"${XDG_CONFIG_HOME:-$HOME/.config}/secretspec/config.toml" 2>/dev/null | sed -E 's/  +/ /g' | mask)"
else
  echo "  secretspec: not installed"
fi
report_footer
