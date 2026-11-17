#!/usr/bin/env bash
# AWS IAM Identity Center: permission sets + assignments for the human user.
#   bash scripts/aws-sso/setup.sh --dry-run   # read-only: shows what it would do
#   bash scripts/aws-sso/setup.sh             # applies (idempotent; re-run is a no-op)
#
# Runs with the current admin credentials (IAM user keys, `default` profile).
# Creates or updates, in the organization instance of Identity Center:
#   Admin     AdministratorAccess (AWS managed), session ADMIN_SESSION (PT8H)
#   Operator  cairo-sim-<stage>-operator (customer managed, from d_abm's Alchemy
#             Operator.ts) + an inline policy copied from fern's instance role
#             (data buckets read, scratch prefix write, analysis RunTask) +
#             CloudWatch Logs read on /cairo-sim/*; session OPERATOR_SESSION (PT12H)
#   CloudBox  ec2 Describe* + Start/Stop/GetConsoleOutput on instances tagged
#             Name=fern only; session CLOUDBOX_SESSION (PT12H)
# and assigns all three, on this account, to the Identity Center user IC_USER
# (default h.fahmi; created from `git config user.email` if missing).
# Nothing is written to the repo. Runbook: docs/plans/2026-11-17-aws-sso-runbook.md
set -euo pipefail
# shellcheck source=scripts/aws-sso/lib.sh
. "$(dirname "$0")/lib.sh"
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    *) die "unknown flag $a" ;;
  esac
done
need awscli2:aws jq:jq -- "$@"

discover
if [ "$IC_STATE" = missing ]; then
  report_header
  cat <<EOF
aws-sso setup: Identity Center NOT enabled in $SSO_REGION (caller $CALLER).
Enable it once in the console (management account, region $SSO_REGION):
  https://$SSO_REGION.console.aws.amazon.com/singlesignon/home?region=$SSO_REGION
  -> Enable -> "Enable with AWS Organizations" (organization instance, NOT an
     account instance: an account instance cannot assign AWS-account
     permission sets). Then re-run this script.
EOF
  report_footer
  exit 0
fi
[ "$IC_STATE" = ACTIVE ] || die "Identity Center instance status is $IC_STATE"
if [ "$ORG_MGMT" != "$ACCOUNT_ID" ]; then
  warn "this account is not the Organizations management account (org: $(printf '%s' "$ORG_MGMT" | mask)); assignments may fail"
fi

CHANGES=0
note_change() { CHANGES=$((CHANGES + 1)); }

# --- the human user ---------------------------------------------------------
USER_ID=$(ic_user_id "$IC_USER")
if [ -n "$USER_ID" ] && [ "$USER_ID" != None ]; then
  USER_STATE=exists
else
  email=${IC_USER_EMAIL:-$(git -C "$REPO" config user.email || true)}
  [ -n "$email" ] || die "no email for the new user: set IC_USER_EMAIL"
  full=$(git -C "$REPO" config user.name || echo "$IC_USER")
  given=${full%% *}
  family=${full#* }
  [ "$family" != "$full" ] || family=$given
  log "creating Identity Center user $IC_USER"
  note_change
  if [ "$DRY_RUN" = 1 ]; then
    echo "   [dry-run] identitystore create-user --user-name $IC_USER (email from git config)" >&2
    USER_ID=DRY-RUN
    USER_STATE=would-create
  else
    USER_ID=$(sso_ identitystore create-user --identity-store-id "$IDENTITY_STORE" \
      --user-name "$IC_USER" --display-name "$full" \
      --name "GivenName=$given,FamilyName=$family" \
      --emails "Value=$email,Type=work,Primary=true" --query UserId --output text)
    USER_STATE=created
  fi
  unset email
fi

# --- policies ---------------------------------------------------------------
CLOUDBOX_POLICY=$(jq -cn --arg name "$NAME" --arg region "$REGION" '{
  Version: "2012-10-17",
  Statement: [
    {Sid: "FindTheBox", Effect: "Allow",
     Action: ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus"], Resource: "*"},
    {Sid: "StartStopTheBox", Effect: "Allow",
     Action: ["ec2:StartInstances", "ec2:StopInstances", "ec2:GetConsoleOutput"],
     Resource: "arn:aws:ec2:\($region):*:instance/*",
     Condition: {StringEquals: {"aws:ResourceTag/Name": $name}}}
  ]}')

# Operator inline: fern's instance-role statements (Sid-prefixed) + logs read.
fern_statements='[]'
FERN_PARTS=
if aws iam get-role --role-name "$FERN_ROLE" >/dev/null 2>&1; then
  for pol in $(aws iam list-role-policies --role-name "$FERN_ROLE" --query 'PolicyNames[]' --output text); do
    doc=$(aws iam get-role-policy --role-name "$FERN_ROLE" --policy-name "$pol" --query PolicyDocument --output json)
    fern_statements=$(jq -c --argjson acc "$fern_statements" --arg p "$pol" '
      ($p | gsub("[^A-Za-z0-9]"; "")) as $pfx
      | [.Statement | if type == "array" then .[] else . end
         | .Sid = ("Fern" + $pfx + (.Sid // ""))] | $acc + .' <<<"$doc")
    FERN_PARTS="$FERN_PARTS $pol"
  done
else
  warn "role $FERN_ROLE not found: Operator gets no data-bucket/scratch statements (deploy infra/aws first, then re-run)"
fi
OPERATOR_POLICY=$(jq -cn --argjson fern "$fern_statements" --arg region "$REGION" --arg acct "$ACCOUNT_ID" '{
  Version: "2012-10-17",
  Statement: ($fern + [
    {Sid: "LogsFind", Effect: "Allow", Action: ["logs:DescribeLogGroups"], Resource: "*"},
    {Sid: "LogsReadCairoSim", Effect: "Allow",
     Action: ["logs:DescribeLogStreams", "logs:GetLogEvents", "logs:FilterLogEvents", "logs:StartLiveTail"],
     Resource: ["arn:aws:logs:\($region):\($acct):log-group:/cairo-sim/*",
                "arn:aws:logs:\($region):\($acct):log-group:/cairo-sim/*:*"]}
  ])}')
OPERATOR_CMP="cairo-sim-$CAIRO_SIM_STAGE-operator"
if policy_exists "$OPERATOR_CMP"; then
  OPERATOR_CMP_STATE=found
else
  warn "customer-managed policy $OPERATOR_CMP not found (d_abm stack not deployed for stage $CAIRO_SIM_STAGE?): Operator without it"
  OPERATOR_CMP_STATE=missing
  OPERATOR_CMP=
fi

# --- permission sets ----------------------------------------------------------
# `wait_status <kind> <request-id>`: poll a provisioning / assignment request.
wait_status() {
  local kind=$1 rid=$2 st i
  for i in $(seq 60); do
    case "$kind" in
      provision) st=$(sso_ sso-admin describe-permission-set-provisioning-status --instance-arn "$INSTANCE_ARN" \
        --provision-permission-set-request-id "$rid" --query 'PermissionSetProvisioningStatus.[Status,FailureReason]' --output text) ;;
      assign) st=$(sso_ sso-admin describe-account-assignment-creation-status --instance-arn "$INSTANCE_ARN" \
        --account-assignment-creation-request-id "$rid" --query 'AccountAssignmentCreationStatus.[Status,FailureReason]' --output text) ;;
    esac
    case "$st" in
      IN_PROGRESS*) sleep 2 ;;
      SUCCEEDED*) return 0 ;;
      *) die "$kind request failed: $(printf '%s' "$st" | mask)" ;;
    esac
    : "$i"
  done
  die "$kind request still in progress after 2 min"
}

# `ensure_ps <name> <session> <description> <aws-managed-arn|-> <customer-managed-name|-> <inline-json|->`
# Sets PS_STATE_<name> and PS_ARN_<name>.
ensure_ps() {
  local name=$1 session=$2 desc=$3 managed=$4 cmp=$5 inline=$6 arn state changed=0 cur
  arn=$(ps_arn "$name")
  if [ -z "$arn" ]; then
    log "creating permission set $name ($session)"
    note_change
    if [ "$DRY_RUN" = 1 ]; then
      echo "   [dry-run] sso-admin create-permission-set --name $name --session-duration $session" >&2
      [ "$managed" = - ] || echo "   [dry-run]   attach managed policy ${managed##*/}" >&2
      [ "$cmp" = - ] || echo "   [dry-run]   attach customer-managed policy $cmp" >&2
      [ "$inline" = - ] || echo "   [dry-run]   inline policy: $(jq -r '[.Statement[].Sid] | join(", ")' <<<"$inline")" >&2
      printf -v "PS_STATE_$name" '%s' would-create
      printf -v "PS_ARN_$name" '%s' DRY-RUN
      return 0
    fi
    arn=$(sso_ sso-admin create-permission-set --instance-arn "$INSTANCE_ARN" --name "$name" \
      --description "$desc" --session-duration "$session" --query PermissionSet.PermissionSetArn --output text)
    state=created
  else
    state=unchanged
    cur=$(sso_ sso-admin describe-permission-set --instance-arn "$INSTANCE_ARN" --permission-set-arn "$arn" \
      --query PermissionSet.SessionDuration --output text)
    if [ "$cur" != "$session" ]; then
      log "$name: session $cur -> $session"
      run sso_ sso-admin update-permission-set --instance-arn "$INSTANCE_ARN" --permission-set-arn "$arn" \
        --session-duration "$session" --description "$desc"
      changed=1
    fi
  fi

  if [ "$managed" != - ]; then
    if ! sso_ sso-admin list-managed-policies-in-permission-set --instance-arn "$INSTANCE_ARN" \
      --permission-set-arn "$arn" --query 'AttachedManagedPolicies[].Arn' --output text | tr '\t' '\n' | grep -qx "$managed"; then
      log "$name: attach ${managed##*/}"
      run sso_ sso-admin attach-managed-policy-to-permission-set --instance-arn "$INSTANCE_ARN" \
        --permission-set-arn "$arn" --managed-policy-arn "$managed"
      changed=1
    fi
  fi
  if [ "$cmp" != - ]; then
    if ! sso_ sso-admin list-customer-managed-policy-references-in-permission-set --instance-arn "$INSTANCE_ARN" \
      --permission-set-arn "$arn" --query 'CustomerManagedPolicyReferences[].Name' --output text | tr '\t' '\n' | grep -qx "$cmp"; then
      log "$name: attach customer-managed $cmp"
      run sso_ sso-admin attach-customer-managed-policy-reference-to-permission-set --instance-arn "$INSTANCE_ARN" \
        --permission-set-arn "$arn" --customer-managed-policy-reference "Name=$cmp,Path=/"
      changed=1
    fi
  fi
  if [ "$inline" != - ]; then
    cur=$(sso_ sso-admin get-inline-policy-for-permission-set --instance-arn "$INSTANCE_ARN" \
      --permission-set-arn "$arn" --query InlinePolicy --output text | canon)
    if [ "$cur" != "$(canon <<<"$inline")" ]; then
      # Not via `run`: the document holds the account ID and bucket names.
      log "$name: inline policy ($(jq -r '[.Statement[].Sid] | join(", ")' <<<"$inline"))"
      if [ "$DRY_RUN" = 1 ]; then
        echo "   [dry-run] sso-admin put-inline-policy-to-permission-set $name" >&2
      else
        sso_ sso-admin put-inline-policy-to-permission-set --instance-arn "$INSTANCE_ARN" \
          --permission-set-arn "$arn" --inline-policy "$inline"
      fi
      changed=1
    fi
  fi

  if [ "$changed" = 1 ]; then
    note_change
    if [ "$state" != created ]; then
      if [ "$DRY_RUN" = 1 ]; then state=would-update; else state=updated; fi
    fi
    # Push changes to accounts that already have this permission set.
    if [ "$DRY_RUN" != 1 ] && [ "$state" = updated ]; then
      local rid
      rid=$(sso_ sso-admin provision-permission-set --instance-arn "$INSTANCE_ARN" --permission-set-arn "$arn" \
        --target-type ALL_PROVISIONED_ACCOUNTS --query PermissionSetProvisioningStatus.RequestId --output text)
      wait_status provision "$rid"
    fi
  fi
  printf -v "PS_STATE_$name" '%s' "$state"
  printf -v "PS_ARN_$name" '%s' "$arn"
}

ensure_ps "$PS_ADMIN" "$ADMIN_SESSION" "Human admin (deploys, console)" \
  arn:aws:iam::aws:policy/AdministratorAccess - -
ensure_ps "$PS_OPERATOR" "$OPERATOR_SESSION" "Run and analyse d_abm (cairo-sim) workloads, no deploys" \
  - "${OPERATOR_CMP:--}" "$OPERATOR_POLICY"
ensure_ps "$PS_CLOUDBOX" "$CLOUDBOX_SESSION" "cloud-box: start/stop/describe the $NAME agent host" \
  - - "$CLOUDBOX_POLICY"

# --- assignments ------------------------------------------------------------
# `ensure_assignment <ps-name>`: USER_ID gets <ps-name> on ACCOUNT_ID.
ensure_assignment() {
  local name=$1 arn has rid var="PS_ARN_$1"
  arn=${!var}
  if [ "$arn" = DRY-RUN ] || [ "$USER_ID" = DRY-RUN ]; then
    echo "   [dry-run] create-account-assignment $name -> $IC_USER" >&2
    printf -v "AS_STATE_$name" '%s' would-assign
    note_change
    return 0
  fi
  has=$(sso_ sso-admin list-account-assignments --instance-arn "$INSTANCE_ARN" --account-id "$ACCOUNT_ID" \
    --permission-set-arn "$arn" --query "length(AccountAssignments[?PrincipalType=='USER' && PrincipalId=='$USER_ID'])" --output text)
  if [ "$has" != 0 ]; then
    printf -v "AS_STATE_$name" '%s' assigned
    return 0
  fi
  log "assigning $name to $IC_USER"
  note_change
  if [ "$DRY_RUN" = 1 ]; then
    echo "   [dry-run] sso-admin create-account-assignment $name -> $IC_USER" >&2
    printf -v "AS_STATE_$name" '%s' would-assign
    return 0
  fi
  rid=$(sso_ sso-admin create-account-assignment --instance-arn "$INSTANCE_ARN" --target-id "$ACCOUNT_ID" \
    --target-type AWS_ACCOUNT --permission-set-arn "$arn" --principal-type USER --principal-id "$USER_ID" \
    --query AccountAssignmentCreationStatus.RequestId --output text)
  wait_status assign "$rid"
  printf -v "AS_STATE_$name" '%s' assigned-now
}
for ps in "$PS_ADMIN" "$PS_OPERATOR" "$PS_CLOUDBOX"; do ensure_assignment "$ps"; done

START_URL="https://$IDENTITY_STORE.awsapps.com/start"
echo
log "access portal (default URL; a customised one is shown in the console, Settings): $START_URL"

report_header
echo "aws-sso setup: dry-run=$DRY_RUN changes=$CHANGES caller=$CALLER"
echo "  instance: $IC_STATE region=$SSO_REGION org-mgmt-is-this-account=$([ "$ORG_MGMT" = "$ACCOUNT_ID" ] && echo yes || echo no)"
echo "  user $IC_USER: $USER_STATE"
[ "$USER_STATE" != created ] || echo "  NOTE: new user: console > Identity Center > Users > $IC_USER > Reset password > send email"
# `st <prefix> <name>`: the PS_STATE_/AS_STATE_ variable set by printf -v above.
st() {
  local v="$1_$2"
  printf '%s' "${!v:-?}"
}
echo "  $PS_ADMIN: $(st PS_STATE "$PS_ADMIN") ($ADMIN_SESSION) assignment=$(st AS_STATE "$PS_ADMIN")"
echo "  $PS_OPERATOR: $(st PS_STATE "$PS_OPERATOR") ($OPERATOR_SESSION) assignment=$(st AS_STATE "$PS_OPERATOR") cmp=cairo-sim-$CAIRO_SIM_STAGE-operator:$OPERATOR_CMP_STATE fern-role-parts:${FERN_PARTS:- none}"
echo "  $PS_CLOUDBOX: $(st PS_STATE "$PS_CLOUDBOX") ($CLOUDBOX_SESSION) assignment=$(st AS_STATE "$PS_CLOUDBOX")"
report_footer
