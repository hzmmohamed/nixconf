# On-demand NixOS agent host "fern" (docs/plans/2026-11-17-aws-agent-host.md).
#
#   cp fern.auto.tfvars.example fern.auto.tfvars   # fill in (gitignored)
#   cp backend.hcl.example backend.hcl             # state bucket (gitignored)
#   export TF_VAR_tailscale_bootstrap_key=tskey-auth-...   # one-time key, first apply only
#   tofu init -backend-config=backend.hcl
#   tofu plan && tofu apply
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
