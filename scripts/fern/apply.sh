#!/usr/bin/env bash
# Create/update fern with OpenTofu (runbook phase 3).
#   bash scripts/fern/apply.sh [--dry-run]
#
# tofu init (S3 backend from backend.hcl) → plan -out → summary → y/N → apply
# of exactly that plan. When the instance does not exist yet, a ONE-TIME
# Tailscale auth key is minted with the stored OAuth client and handed to tofu
# as TF_VAR_tailscale_bootstrap_key in this process's environment only; it is
# never printed or written to disk (tofu stores user_data as a hash).
# --dry-run: init without backend + validate + print the plan steps; no key,
# no API call, no apply.
set -euo pipefail
# shellcheck source=scripts/fern/lib.sh
. "$(dirname "$0")/lib.sh"
[ "${1:-}" = --dry-run ] && DRY_RUN=1
need opentofu:tofu awscli2:aws jq:jq curl:curl sops:sops -- "$@"

[ -r "$TFVARS" ] || die "$TFVARS missing"
[ -r "$BACKEND" ] || die "$BACKEND missing"
cd "$INFRA"
plan=fern.tfplan
# The plan file holds variable values in clear (the one-time key): shred it.
trap 'shred -u "$INFRA/$plan" 2>/dev/null || true' EXIT

if [ "$DRY_RUN" = 1 ]; then
  log "dry-run: tofu init -backend=false + validate"
  tofu init -input=false -backend=false >/dev/null
  tofu validate -no-color
  echo "   [dry-run] tofu init -reconfigure -backend-config=backend.hcl" >&2
  echo "   [dry-run] (instance absent) mint one-time Tailscale key → TF_VAR_tailscale_bootstrap_key" >&2
  echo "   [dry-run] tofu plan -out=$plan; show summary; y/N; tofu apply $plan" >&2
  report_header
  echo "apply: dry-run OK (validate passed)"
  report_footer
  exit 0
fi

aws_ s3api head-bucket --bucket "$(backend_var bucket)" 2>/dev/null ||
  die "state bucket missing: bash scripts/fern/state-bucket.sh (phase 1)"
log "tofu init (S3 backend)"
tofu init -input=false -reconfigure -backend-config=backend.hcl >/dev/null

minted=no
if tofu state list 2>/dev/null | grep -qx 'aws_instance.agent_host'; then
  log "instance already in state: no bootstrap key needed (user_data changes are ignored)"
else
  # A stale node would make the new one fern-1 (MagicDNS) and break the registry.
  if tailscale status >/dev/null 2>&1 && [ -n "$(ts_peer || true)" ]; then
    die "a '$NAME' node already exists in the tailnet. Remove it first: https://login.tailscale.com/admin/machines"
  fi
  secret=
  ts_stored_secret secret
  ts_token "$secret" || die "the stored OAuth client secret does not work (phase 2)"
  unset secret
  TF_VAR_tailscale_bootstrap_key=
  ts_mint_key "$TS_TOKEN" TF_VAR_tailscale_bootstrap_key || die "could not mint the bootstrap key"
  export TF_VAR_tailscale_bootstrap_key
  minted=yes
  log "minted a one-time, pre-authorized key for $(fern_tags_json) (valid 1 day; not shown)"
fi

log "tofu plan"
set +e
tofu plan -input=false -no-color -detailed-exitcode -out="$plan" >"$INFRA/.plan.log" 2>&1
rc=$?
set -e
if [ "$rc" = 1 ]; then
  cat "$INFRA/.plan.log" >&2
  rm -f "$INFRA/.plan.log"
  die "tofu plan failed"
fi
rm -f "$INFRA/.plan.log"

echo
echo "---- plan summary ----"
tofu show -no-color "$plan" | grep -E '^  # |^Plan:|^No changes' || true
echo "----------------------"

applied=no
if [ "$rc" = 0 ]; then
  log "no changes"
elif confirm "Apply this plan?"; then
  tofu apply -input=false -no-color "$plan" | grep -E 'Creation complete|Modifications complete|Destruction complete|Apply complete|Error' || true
  applied=yes
fi

report_header
echo "apply: applied=$applied minted-key=$minted"
if [ "$applied" = yes ] || [ "$rc" = 0 ]; then
  echo "ami_boot_mode=$(tofu output -raw ami_boot_mode 2>/dev/null || echo ?)"
  id=$(tofu output -raw instance_id 2>/dev/null || true)
  [ -n "$id" ] && aws_ ec2 describe-instances --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].[State.Name,InstanceType,InstanceLifecycle,Placement.AvailabilityZone]' \
    --output text | awk '{print "instance: state=" $1 " type=" $2 " market=" $3 " az=" $4}'
fi
report_footer
