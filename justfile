# Agent-friendly checks. Every recipe is a thin wrapper; the raw command is
# shown next to it so it also works without `just` installed.

# List recipes
default:
    @just --list

# --- deploy + repo sync (modules/packages/deploy.nix; from hazel or butternut) ---
# Runs the repo's own `deploy` (nix run), so registry edits apply at once.

# `just deploy <host> [switch|boot|test|dry-activate] [--dry-run] [--plan]` (raw: nix run .#deploy -- <host> ...)
deploy host *args:
    DEPLOY_FLAKE={{justfile_directory()}} nix run {{justfile_directory()}}#deploy -- {{host}} {{args}}

# Every reachable host, this machine last, then an OK/unreachable/failed table (raw: nix run .#deploy -- all ...)
deploy-all *args:
    DEPLOY_FLAKE={{justfile_directory()}} nix run {{justfile_directory()}}#deploy -- all {{args}}

# Where would `deploy <host>` build/copy/activate? Runs nothing (raw: nix run .#deploy -- --plan <host>)
deploy-plan host="all":
    DEPLOY_FLAKE={{justfile_directory()}} nix run {{justfile_directory()}}#deploy -- --plan {{host}}

# --- deploy visibility (modules/packages/fleet.sh; read-only, eval only) ---

# Hosts whose system changes between base (default: merge-base with main) and the working tree (raw: nix run .#fleet -- affects [base])
affects base="":
    FLEET_REPO={{justfile_directory()}} nix run {{justfile_directory()}}#fleet -- affects {{base}}

# Per host: deployed commit vs main, and whether its running system differs from main's (raw: nix run .#fleet -- status)
status:
    FLEET_REPO={{justfile_directory()}} nix run {{justfile_directory()}}#fleet -- status

# Fetch the other desktop's repo, fast-forward main, push this branch to its side ref (raw: nix run .#nixconf-sync -- [--dry-run])
sync *args:
    NIXCONF_SYNC_REPO={{justfile_directory()}} nix run {{justfile_directory()}}#nixconf-sync -- {{args}}

# Branches merged into main + their worktrees; dry run, --apply removes them (raw: bash scripts/repo/prune-worktrees.sh [--apply])
prune-worktrees *args:
    bash {{justfile_directory()}}/scripts/repo/prune-worktrees.sh {{args}}

# Dry run of the GitHub history scrub (raw: bash scripts/repo/scrub-unpushed-history.sh [--apply])
scrub-history *args:
    bash scripts/repo/scrub-unpushed-history.sh {{args}}

# Format everything with treefmt/alejandra (raw: nix fmt)
fmt:
    nix fmt

# Fail if anything is unformatted; read-only, runs treefmt in the sandbox
# (raw: nix build --no-link .#checks.x86_64-linux.treefmt)
fmt-check:
    nix build --no-link .#checks.x86_64-linux.treefmt

# deadnix (fatal) + statix (advisory; config in statix.toml)
# (raw: nix shell --inputs-from . nixpkgs#deadnix nixpkgs#statix -c sh -c 'deadnix --fail modules; statix check modules')
lint:
    nix shell --inputs-from . nixpkgs#deadnix nixpkgs#statix -c sh -c 'deadnix --fail modules && { statix check modules || echo "statix: warnings above are advisory"; }'

# Evaluate one host, no build (raw: nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath)
eval host:
    nix eval --raw .#nixosConfigurations.{{host}}.config.system.build.toplevel.drvPath && echo

# Known-broken configurations that eval-all reports as SKIP instead of FAIL.
# niri-desktop-vm: the wrapped niri config (wrappedPrograms/niri.nix) no longer
# validates against niri 26.04, so its IFD build fails. Remove from here once
# fixed or deleted.
skip := "niri-desktop-vm"

# Evaluate every nixosConfiguration, print OK/FAIL per host (~10 s each)
eval-all:
    #!/usr/bin/env bash
    set -u
    skip=" {{skip}} "
    hosts=$(nix eval --json .#nixosConfigurations --apply builtins.attrNames 2>/dev/null | tr -d '[]"' | tr ',' ' ')
    fail=0
    for h in $hosts; do
      if [[ "$skip" == *" $h "* ]]; then echo "SKIP $h (known broken, see justfile)"; continue; fi
      if out=$(nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath" 2>&1); then
        echo "OK   $h"
      else
        echo "FAIL $h"
        echo "$out" | grep -E 'error' | tail -n 3 | sed 's/^/       /'
        fail=1
      fi
    done
    exit $fail

# Everything an agent should run before handing work back
check: fmt-check lint eval-all

# --- fern (AWS agent host): docs/plans/2026-11-17-fern-runbook.md -----------
# Each recipe is `bash scripts/fern/<x>.sh`; pass --dry-run to preview.

# Phase 1: state bucket + read-only preflight (raw: bash scripts/fern/state-bucket.sh && bash scripts/fern/preflight.sh)
fern-prep *args:
    bash scripts/fern/state-bucket.sh {{args}} && bash scripts/fern/preflight.sh

# Phase 2: store the Tailscale OAuth client (raw: bash scripts/fern/tailscale.sh store)
fern-tailscale *args:
    bash scripts/fern/tailscale.sh {{args}}

# Phase 2: read-only deploy key on the work repos + secrets/fern/workspace.yaml (raw: bash scripts/fern/deploy-key.sh)
fern-deploy-key *args:
    bash scripts/fern/deploy-key.sh {{args}}

# Phase 3: tofu init/plan/apply with a freshly minted one-time Tailscale key (raw: bash scripts/fern/apply.sh)
fern-apply *args:
    bash scripts/fern/apply.sh {{args}}

# Phase 4: wait for fern, fill registry + .sops.yaml, sops updatekeys (raw: bash scripts/fern/enroll.sh)
fern-enroll *args:
    bash scripts/fern/enroll.sh {{args}}

# Phase 5: role / S3 / units / login checks on fern (raw: bash scripts/fern/verify.sh)
fern-verify *args:
    bash scripts/fern/verify.sh {{args}}

# --- tailnet as code (OpenTofu, infra/tailscale): docs/plans/2026-11-17-tailnet-as-code.md

# Store the admin OAuth client (tofu credential) in sops (raw: bash scripts/tailscale/store-admin.sh)
tailnet-store-admin *args:
    bash scripts/tailscale/store-admin.sh {{args}}

# Validate the policy + plan the tailnet, imports included; read-only (raw: bash scripts/tailscale/plan.sh)
tailnet-plan:
    bash scripts/tailscale/plan.sh

# Plan, y/N, apply (raw: bash scripts/tailscale/apply.sh)
tailnet-apply:
    bash scripts/tailscale/apply.sh

# --- AWS Identity Center (SSO): docs/plans/2026-11-17-aws-sso-runbook.md -----
# Pass --dry-run to preview (setup/store).

# Permission sets Admin/Operator/CloudBox + assignments (raw: bash scripts/aws-sso/setup.sh)
aws-sso-setup *args:
    bash scripts/aws-sso/setup.sh {{args}}

# account_id/start_url/region -> sops secrets/shared/aws-sso.yaml (raw: bash scripts/aws-sso/store-config.sh)
aws-sso-store *args:
    bash scripts/aws-sso/store-config.sh {{args}}

# Read-only checks of the SSO profiles after `aws-login` (raw: bash scripts/aws-sso/verify.sh)
aws-sso-verify:
    bash scripts/aws-sso/verify.sh
