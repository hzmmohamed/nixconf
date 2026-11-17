#!/usr/bin/env bash
# Post-deploy checks on fern (runbook phase 5). Read-only except one tiny
# object written to and deleted from the scratch prefix.
#   bash scripts/fern/verify.sh [--dry-run]
# Bucket names come from the local, gitignored infra/aws/fern.auto.tfvars.
set -euo pipefail
# shellcheck source=scripts/fern/lib.sh
. "$(dirname "$0")/lib.sh"
[ "${1:-}" = --dry-run ] && DRY_RUN=1

user=$(nix eval --raw "$REPO#user.name")
ip=$(nix eval --raw "$REPO#hosts.$NAME.ts4" 2>/dev/null || true)
[ -n "$ip" ] || [ "$DRY_RUN" = 1 ] || die "fern has no ts4 in the registry yet (phase 4)"
scratch_bucket=$(tfvar scratch_bucket_name)
scratch_prefix=$(tfvar scratch_prefix)
mapfile -t buckets < <(tfvar_list data_bucket_names)
[ -n "$scratch_bucket" ] && [ ${#buckets[@]} -gt 0 ] || die "could not read buckets from $TFVARS"

# Runs on fern (expands there, hence single quotes). Arguments: scratch
# bucket, scratch prefix, data buckets…
# shellcheck disable=SC2016
remote_script='
set -u
sb=$1 sp=$2
shift 2
r() { printf "%-6s %s\n" "$1" "$2"; }
r INFO "$(hostname) $(nixos-version)"
if arn=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null); then
  role=${arn#*:assumed-role/}
  r OK "instance role: ${role%%/*}"
else
  r FAIL "no instance role credentials (IMDS)"
fi
for b in "$@"; do
  if n=$(s5cmd ls "s3://$b/*" 2>/dev/null | head -n 3 | wc -l) && [ "$n" -gt 0 ]; then
    r OK "read s3://$b ($n+ objects listed)"
  else
    r FAIL "read s3://$b"
  fi
done
obj="s3://$sb/${sp}_access-test-$(date +%s).txt"
if echo "fern access test" | aws s3 cp - "$obj" >/dev/null 2>&1 && aws s3 rm "$obj" >/dev/null 2>&1; then
  r OK "write+delete in the scratch prefix"
else
  r FAIL "write to the scratch prefix"
fi
deny="s3://$sb/_fern-denied-test-$(date +%s).txt"
if echo "must fail" | aws s3 cp - "$deny" >/dev/null 2>&1; then
  aws s3 rm "$deny" >/dev/null 2>&1
  r FAIL "write OUTSIDE the scratch prefix succeeded (role too broad)"
else
  r OK "write outside the scratch prefix denied"
fi
for u in t3code; do
  r "$( [ "$(systemctl --user is-active "$u")" = active ] && echo OK || echo FAIL)" "user unit $u"
done
r "$( [ "$(systemctl --user show -p Result --value workspace-bootstrap)" = success ] && echo OK || echo FAIL)" "workspace-bootstrap (clone)"
for d in "$HOME"/work/tfc/repos/*/; do [ -d "$d/.git" ] && r OK "checkout ${d%/}"; done
if [ -f "$HOME/.claude/.credentials.json" ]; then r OK "claude logged in"; else r TODO "claude not logged in (ssh fern, claude, /login)"; fi
r INFO "cloud-idle: $(cloud-idle status 2>/dev/null | head -n 1)"
'

if [ "$DRY_RUN" = 1 ]; then
  echo "   [dry-run] ssh -p $SSH_PORT $user@<fern ts4> bash -s -- <scratch> <prefix> <${#buckets[@]} data buckets>" >&2
  report_header
  echo "verify: dry-run (would test the role, ${#buckets[@]} reads, scratch write, denied write, units)"
  report_footer
  exit 0
fi

out=$(ssh -p "$SSH_PORT" -o ConnectTimeout=10 -o BatchMode=yes "$user@$ip" \
  bash -s -- "$scratch_bucket" "$scratch_prefix" "${buckets[@]}" <<<"$remote_script")

report_header
printf '%s\n' "$out"
report_footer
