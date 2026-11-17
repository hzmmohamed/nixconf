# On-demand NixOS agent host "fern" (docs/plans/2026-11-17-aws-agent-host.md).
#
# Driven by scripts/fern/ (runbook: docs/plans/2026-11-17-fern-runbook.md):
#   state-bucket.sh  creates the state bucket named in backend.hcl
#   apply.sh         tofu init -backend-config=backend.hcl, mints the one-time
#                    Tailscale key (TF_VAR_tailscale_bootstrap_key), plan, y/N, apply
# fern.auto.tfvars and backend.hcl are gitignored (see the *.example files).
#
# Local validation without a backend: tofu init -backend=false && tofu validate
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial configuration: bucket/key/region/use_lockfile come from
  # backend.hcl (S3-native locking, no DynamoDB table).
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.cost_tag
      ManagedBy = "opentofu/nixconf"
    }
  }
}
