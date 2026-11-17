# Tailnet as code (docs/plans/2026-11-17-tailnet-as-code.md).
#
# Driven by scripts/tailscale/ (never run tofu here by hand without them:
# they export the admin OAuth client from sops into tofu's environment only):
#   store-admin.sh  admin OAuth client secret → secrets/admin/tailscale-admin.yaml
#   plan.sh         backend.hcl + hosts.auto.tfvars.json, init, plan (imports first)
#   apply.sh        same plan, y/N, apply; writes a rotated hosts client into sops
#
# Local validation without a backend or credentials:
#   tofu init -backend=false && tofu validate
terraform {
  # >= 1.7 for import blocks with for_each, >= 1.10 for S3 use_lockfile.
  required_version = ">= 1.10"

  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.30.0"
    }
  }

  # Partial configuration: backend.hcl (gitignored) is generated from
  # infra/aws/backend.hcl with key = "tailscale/terraform.tfstate".
  backend "s3" {}
}

# Credentials come from the environment, set by scripts/tailscale/lib.sh:
#   TAILSCALE_OAUTH_CLIENT_ID / TAILSCALE_OAUTH_CLIENT_SECRET (admin client, sops)
#   TAILSCALE_TAILNET = "-" (the tailnet that owns the credential)
provider "tailscale" {}
