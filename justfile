# Agent-friendly checks. Every recipe is a thin wrapper; the raw command is
# shown next to it so it also works without `just` installed.

# List recipes
default:
    @just --list

# `just deploy hazel [boot|test]` — see modules/nixos/features/remote-deploy.nix
deploy host action="switch":
    DEPLOY_FLAKE={{justfile_directory()}} deploy {{host}} {{action}}

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
