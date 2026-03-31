# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Multi-host NixOS configuration built on **flake-parts** with **import-tree** for automatic module discovery. Every `.nix` file under `modules/` is automatically a flake-parts module.

## Common commands

```bash
# Enter dev shell (nix tools, sops, age, formatters, git hooks)
nix develop

# Build a host (butternut, maple, peacelily)
nix build .#nixosConfigurations.<host>.config.system.build.toplevel

# Apply config on current host
sudo nixos-rebuild switch --flake .

# Format all files (alejandra)
treefmt

# List all flake outputs
nix flake show

# Edit/create encrypted secrets
sops secrets/<host>/<name>.yaml

# Run a test VM
nix build .#nixosConfigurations.desktop-vm.config.system.build.vm && ./result/bin/run-desktop-vm-vm
```

## Architecture overview

See `ARCHITECTURE.md` for the full design document. Key points:

**Module layers:**
- `modules/user.nix` — single source of truth for username (`flake.user`)
- `modules/theme.nix` — centralized color palettes (`flake.theme`, `flake.catppuccin`, `flake.catppuccinMocha`)
- `modules/nixos/base/` — option declarations (`preferences.*`, `persistance.*`)
- `modules/nixos/features/` — composable NixOS modules (each exports `flake.nixosModules.<name>`)
- `modules/nixos/extra/` — integration layers (home-manager bridge, impermanence)
- `modules/nixos/hosts/` — per-host configs that compose features via imports
- `modules/wrappedPrograms/` — standalone packages with baked-in config (use `self.user`/`self.theme`, not NixOS config)
- `modules/vms/` — test VMs for desktop environments

**Data flow:** Host config imports `base` + `general` + `desktop` + WM module + feature modules. Feature modules read `preferences.*` options set by base. Wrapped programs are `perSystem.packages.*` that access flake-level attrs only.

## Critical invariants

- **Never hardcode usernames** — use `config.preferences.user.name` in NixOS modules, `self.user` in wrapped programs
- **Never hardcode hex color values** — use `self.theme`, `self.catppuccin`, or `self.catppuccinMocha`
- **Feature modules are independent** — they don't import other features (except `desktop` which aggregates shared desktop basics). Hosts compose features.
- **Features own their infrastructure** — if a feature needs syncthing/sops, it declares them (see `shared-zotero.nix` pattern)
- **Secrets follow `secrets/<hostname>/`** — resolved via `config.networking.hostName`, never hardcode hostnames
- **Files must be `git add`'ed** — Nix flakes only see git-tracked files
- **`extra_hjem` uses home-manager** — the module name is historical; it wraps `home-manager.nixosModules.home-manager` with Catppuccin integration

## Hosts

| Host | WM | Notes |
|------|----|-------|
| butternut | Sway | ASUS laptop, greetd, SSH:7654, asusd |
| maple | Niri + Noctalia | Workstation, SSH:7654 |
| peacelily | None | AI server (Ollama), no desktop |

## Secrets

sops-nix with age encryption. Key at `~/.config/sops/age/keys.txt` (not in repo). Rules in `.sops.yaml`.

## Code style

- Formatter: **alejandra** (enforced by treefmt and git pre-commit hook)
- Linter: **deadnix** (pre-commit hook checks for unused variables)
- Static analysis: **statix** (available in dev shell)
