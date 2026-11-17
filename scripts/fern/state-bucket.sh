#!/usr/bin/env bash
# Create the OpenTofu state bucket named in infra/aws/backend.hcl (gitignored):
# versioning on, all public access blocked, SSE-S3, bucket-owner-enforced.
# Idempotent: an existing bucket you own is only (re)configured.
#   bash scripts/fern/state-bucket.sh [--dry-run]
set -euo pipefail
# shellcheck source=scripts/fern/lib.sh
. "$(dirname "$0")/lib.sh"
[ "${1:-}" = --dry-run ] && DRY_RUN=1
need awscli2:aws -- "$@"

bucket=$(backend_var bucket)
region=$(backend_var region)
[ -n "$bucket" ] && [ -n "$region" ] || die "bucket/region missing in $BACKEND"
acct=$(aws_ sts get-caller-identity --query Account --output text) || die "no AWS credentials (AWS_PROFILE?)"

if aws --region "$region" s3api head-bucket --bucket "$bucket" --expected-bucket-owner "$acct" 2>/dev/null; then
  log "state bucket exists and is yours; reconfiguring (idempotent)"
  created=no
else
  # 403 = someone else's bucket with that name; 404 = free.
  if aws --region "$region" s3api head-bucket --bucket "$bucket" 2>&1 | grep -q 403; then
    die "a bucket with that name exists in another account; change bucket in $BACKEND"
  fi
  log "creating state bucket in $region"
  run aws --region "$region" s3api create-bucket --bucket "$bucket" \
    --create-bucket-configuration "LocationConstraint=$region" \
    --object-ownership BucketOwnerEnforced >/dev/null
  created=yes
  if [ "$DRY_RUN" = 1 ]; then created=would-create; fi
fi

run aws --region "$region" s3api put-public-access-block --bucket "$bucket" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
run aws --region "$region" s3api put-bucket-versioning --bucket "$bucket" \
  --versioning-configuration Status=Enabled
run aws --region "$region" s3api put-bucket-encryption --bucket "$bucket" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
run aws --region "$region" s3api put-bucket-tagging --bucket "$bucket" \
  --tagging 'TagSet=[{Key=Project,Value=agent-box},{Key=ManagedBy,Value=scripts/fern}]'

if [ "$DRY_RUN" = 1 ]; then
  versioning=dry-run
  pab=dry-run
else
  versioning=$(aws --region "$region" s3api get-bucket-versioning --bucket "$bucket" --query Status --output text)
  pab=$(aws --region "$region" s3api get-public-access-block --bucket "$bucket" \
    --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text | tr '\t' ,)
fi

report_header
echo "state-bucket: created=$created versioning=$versioning public-access-block=$pab sse=AES256 dry-run=$DRY_RUN"
report_footer
