# Shared helpers for scripts/aws-sso/*.sh (sourced, not executed).
# Runbook: docs/plans/2026-11-17-aws-sso-runbook.md
#
# Same conventions as scripts/fern/ (whose lib.sh this reuses): bash, paste-
# only, idempotent, --dry-run first, and a REPORT BACK block at the end.
# Run with the CURRENT admin credentials (IAM user, `default` profile) until
# the SSO profiles work. Identifiers (account ID, identity store ID, start
# URL, ARNs, emails) are looked up at runtime and never written into the repo;
# the REPORT BACK block masks them.
# shellcheck shell=bash
# shellcheck disable=SC2034

# shellcheck source=scripts/fern/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../fern" && pwd)/lib.sh"

# Identity Center lives in the account's home region (eu-central-1).
SSO_REGION=${SSO_REGION:-$REGION}
SESSION_NAME=tfc
CONFIG_REL=secrets/shared/aws-sso.yaml
CONFIG_FILE="$REPO/$CONFIG_REL"

# The human's Identity Center user. An `h.fahmi` user already exists in the
# identity store (created 2023, work email); it is reused. Only when it is
# missing is a new one created, with the email from `git config user.email`
# (override: IC_USER_EMAIL).
IC_USER=${IC_USER:-h.fahmi}

# Permission sets (names are what `sso_role_name` in ~/.aws/config refers to;
# keep them in sync with preferences.aws.sso.profiles in features/aws.nix).
PS_ADMIN=Admin
PS_OPERATOR=Operator
PS_CLOUDBOX=CloudBox
ADMIN_SESSION=${ADMIN_SESSION:-PT8H}
OPERATOR_SESSION=${OPERATOR_SESSION:-PT12H}
CLOUDBOX_SESSION=${CLOUDBOX_SESSION:-PT12H}

# d_abm stage whose customer-managed operator policy (Alchemy
# infra/aws/src/Operator.ts: cairo-sim-<stage>-operator) Operator attaches.
CAIRO_SIM_STAGE=${CAIRO_SIM_STAGE:-dev}
# fern's instance role (infra/aws/iam.tf): its inline policies (data-access,
# ecs-run-analysis-task) are copied into Operator, so the bucket names stay in
# the gitignored tfvars and in AWS.
FERN_ROLE=${FERN_ROLE:-$NAME-agent-host}

sso_() { aws --region "$SSO_REGION" "$@"; }

# `mask`: hide account IDs, identity store / instance IDs, UUIDs and emails
# in text meant for the REPORT BACK block.
mask() {
  sed -E 's/[0-9]{12}/<ACCOUNT>/g; s/d-[0-9a-f]{10}/d-<ID>/g; s/ssoins-[0-9a-f]+/ssoins-<ID>/g;
    s/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<uuid>/g;
    s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+/<email>/g'
}

# Sets ACCOUNT_ID, CALLER (masked), INSTANCE_ARN, IDENTITY_STORE, ORG_MGMT.
discover() {
  local ident n
  ident=$(aws sts get-caller-identity --output json) ||
    die "no working AWS credentials (the current admin keys: AWS_PROFILE=default?)"
  ACCOUNT_ID=$(printf '%s' "$ident" | jq -r .Account)
  CALLER=$(printf '%s' "$ident" | jq -r .Arn | mask)
  n=$(sso_ sso-admin list-instances --query 'length(Instances)' --output text) ||
    die "sso-admin list-instances failed (permissions? region $SSO_REGION?)"
  if [ "$n" = 0 ]; then
    IC_STATE=missing
    return 0
  fi
  [ "$n" = 1 ] || die "expected one Identity Center instance, found $n"
  INSTANCE_ARN=$(sso_ sso-admin list-instances --query 'Instances[0].InstanceArn' --output text)
  IDENTITY_STORE=$(sso_ sso-admin list-instances --query 'Instances[0].IdentityStoreId' --output text)
  IC_STATE=$(sso_ sso-admin list-instances --query 'Instances[0].Status' --output text)
  ORG_MGMT=$(aws organizations describe-organization --query Organization.MasterAccountId --output text 2>/dev/null || echo none)
}

# `ps_arn <name>`: ARN of the permission set called <name>, or empty.
ps_arn() {
  local arn name
  for arn in $(sso_ sso-admin list-permission-sets --instance-arn "$INSTANCE_ARN" --query 'PermissionSets[]' --output text); do
    name=$(sso_ sso-admin describe-permission-set --instance-arn "$INSTANCE_ARN" --permission-set-arn "$arn" \
      --query PermissionSet.Name --output text)
    if [ "$name" = "$1" ]; then
      printf '%s\n' "$arn"
      return 0
    fi
  done
}

# `ic_user_id <username>`: the identity store user ID, or empty.
ic_user_id() {
  sso_ identitystore get-user-id --identity-store-id "$IDENTITY_STORE" \
    --alternate-identifier "{\"UniqueAttribute\":{\"AttributePath\":\"userName\",\"AttributeValue\":\"$1\"}}" \
    --query UserId --output text 2>/dev/null || true
}

# `policy_exists <name>`: a customer-managed IAM policy at path / exists.
policy_exists() {
  aws iam get-policy --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$1" >/dev/null 2>&1
}

# Canonical JSON (sorted keys, compact) for comparisons.
canon() { jq -cS . 2>/dev/null || true; }
