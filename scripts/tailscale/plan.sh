#!/usr/bin/env bash
# Plan the tailnet (policy, DNS, settings, hosts OAuth client, device tags).
#   bash scripts/tailscale/plan.sh
#   env TAILNET_DEVICE_TAGS=1 bash scripts/tailscale/plan.sh   # + registry tags
#
# Read-only: writes only the gitignored backend.hcl / hosts.auto.tfvars.json.
# Existing objects are adopted by `import` blocks in the HCL, which a plan
# only previews (nothing is written to state or the API until apply.sh), so
# re-running is always safe. The provider validates the policy and its
# `tests` against the API. Needs AWS credentials for the state bucket.
set -euo pipefail
# shellcheck source=scripts/tailscale/lib.sh
. "$(dirname "$0")/lib.sh"
for a in "$@"; do die "unknown flag $a"; done
prepare "$@"
make_plan

report_header
echo "tailnet plan: changes=$([ "$PLAN_RC" = 2 ] && echo yes || echo no) backend.hcl=$BACKEND_STATE"
echo "  scopes: $TS_SCOPES"
echo "  managed: acl=yes dns=yes settings=$MANAGE_SETTINGS hosts-client=$MANAGE_HOSTS_CLIENT devices=$MANAGE_DEVICES"
echo "  tagged hosts (registry): $TAGGED_HOSTS"
plan_report
report_footer
