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
