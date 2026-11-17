# CLAUDE.md

Guidance for coding agents (Claude Code, OpenCode, …) working in this repo.
`AGENTS.md` is a symlink to this file.

## What this is

Multi-host NixOS flake (nixos-26.05) built on **flake-parts** + **import-tree**:
every `.nix` file under `modules/` is a flake-parts module, picked up
automatically. Single user (name in `modules/user.nix`). Public repo.

## Hosts

| Host | Role | Notes |
|------|------|-------|
| butternut | Main workstation | ASUS TUF laptop used as a **desktop**: broken internal panel, external monitor, always on AC. Sway. NVIDIA RTX 3050 (PRIME offload, dGPU kept awake for CUDA), LTS kernel. Split files: `hosts/butternut/{gpu,power,audio,games,network}.nix` |
| hazel | Carried laptop / client | ThinkPad E14 Gen 2 (i5-1135G7). Sway, greetd, battery-aware |
| maple | Headless always-on node | Laptop with a dead screen, lid closed. No desktop: SSH/Tailscale, syncthing, nix-serve, docker/k8s CLI. Lid/suspend ignored, user lingering |
| peacelily | Headless GPU AI server | NVIDIA, llama-swap, Wyoming STT/TTS, Qdrant, LibreChat. **Not yet redeployed** with the current config |

Test VMs: `desktop-vm` (Sway), `niri-desktop-vm` (Niri; currently broken, see below).
SSH on every host: port 7654.

## Golden commands

```bash
just fmt              # format (raw: nix fmt)
just lint             # deadnix (fatal) + statix (advisory)
just eval <host>      # eval one host, no build
just eval-all         # eval every nixosConfiguration: OK / FAIL / SKIP per host
just check            # fmt-check + lint + eval-all — run before handing work back
```

`just` is in the dev shell (`nix develop --impure`, or direnv). Without it, the
raw command sits next to each recipe in `justfile`, e.g.

```bash
nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath
nix build --no-link .#checks.x86_64-linux.<host>-eval   # same, as a flake check
nix build --no-link .#checks.x86_64-linux.treefmt       # read-only format check
```

Eval is ~10 s per host (`eval-all` ≈ 1 min cold). `nix flake check --no-build`
and `nix flake show` work in pure mode, but `flake check` currently fails on
known-broken outputs (see "Current state").

Building (only when asked; NVIDIA/CUDA builds are long):
`nix build .#nixosConfigurations.<host>.config.system.build.toplevel`

**Never run from an agent** (denied in `.claude/settings.json`; the user does
these): `nixos-rebuild`, `deploy` / `just deploy`, `scripts/install-host.sh`,
`nixos-anywhere`, `disko`, `sops`, `age`, `nix copy`, `doas`/`sudo`,
`git push`, `rm -r`. Deploys: `just deploy <host> [switch|boot|test]`
(`remote-deploy` feature); installs: `scripts/install-host.sh <host> <ip>`.

## Layout

```
modules/
  user.nix, theme.nix, ssh-keys.nix   flake-level data: self.user, palettes/fonts, self.sshKeys
  flake-parts.nix                     systems (x86_64-linux only), mergeable flake options
  devshell.nix                        devenv shell + treefmt (alejandra) + git hooks
  checks.nix                          checks.<host>-eval (eval-only)
  nixos/base/        option declarations → flake.nixosModules.base
  nixos/features/    one flake.nixosModules.<name> per file (or dir)
  nixos/extra/       integration layers: extra_hjem (home-manager bridge), extra_theme, impermanence
  nixos/hosts/<h>/   configuration.nix, hardware-configuration.nix, disko.nix, + split files
  wrappedPrograms/   perSystem.packages with baked-in config (fish, kitty, git, neovim, …)
  packages/          other perSystem packages
  vms/               test VMs
docs/plans/          designs, backlog, user action list
secrets/             sops files (see secrets/README.md)
scripts/             install-host.sh (nixos-anywhere)
```

Base options (`modules/nixos/base/`): `preferences.user.{name,passwordFromSops}`,
`preferences.theme.{source,palette,stateDir,files,dconf,reloadHooks}`,
`preferences.keyboard`, `preferences.keymap`, `preferences.monitors`,
`preferences.autostart`, `preferences.desktopShell` (`waybar`|`noctalia`),
`preferences.desktop.enable` (set by the `desktop` feature; gates GUI bits in
modules every host imports, e.g. `gtk`, the Tailscale tray), `persistance.*`.
Features declare their own `preferences.<feature>.*` (e.g. `preferences.ssh`
in `openssh`, `preferences.nix-serve`, `preferences.syncthing`).

Host composition: `base` + `general` (+ `desktop` + WM for GUI hosts) +
features. Large hosts split concerns into extra files under `hosts/<host>/`
(`gpu.nix`, `power.nix`, `audio.nix`, `games.nix`, `network.nix`,
`agents.nix`), each contributing to the same `flake.nixosModules.host<Name>`.

## Invariants

- **Usernames**: `config.preferences.user.name` in NixOS modules, `self.user`
  in wrapped programs. Never hardcode.
- **Colours**: new code takes colours from `config.preferences.theme.palette.{light,dark}`
  and registers palette files via `preferences.theme.files` (light/dark switch
  via `theme-mode`). Don't use `self.catppuccin`/`self.theme` directly in new
  code; never hardcode hex.
- **Hostnames**: `config.networking.hostName`; never hardcode in features.
- **Secrets**: `secrets/<hostname>/<service>.yaml`, shared ones in
  `secrets/shared/`; paths built from `config.networking.hostName`.
- **Features are independent**: a feature doesn't import other features
  (exception: `desktop` aggregates desktop basics; `general` pulls the user
  shell/theme/nix basics). Hosts compose.
- **Features own their infrastructure**: sops secrets, syncthing folders,
  firewall ports live in the feature (see `shared-zotero.nix`).
- **home-manager, not hjem**: `extra_hjem` is a historical name; it wraps
  `home-manager.nixosModules.home-manager` (+ catppuccin modules). Use
  `home-manager.users.${user}`.
- **Style**: alejandra formatting, deadnix-clean. `{...}:` module headers are
  the convention (statix `empty_pattern` is disabled).

## Agent hazards

- **Flakes only see git-tracked files.** After creating a file: `git add -N <file>`.
  An untracked file referenced from Nix fails eval with "not tracked by Git".
- **Shared working tree/index.** Several agents may work at once; use a git
  worktree per agent for anything non-trivial, re-read files right before
  editing, never `git add -A`/`git stash`/re-lock inputs you didn't add, don't
  run `nix flake update` unless asked.
- **Long builds**: NVIDIA kernel modules, CUDA (llama.cpp), etc. Prefer eval.
- **Tools in agent shells**: whether the dev shell is loaded depends on how
  the agent was started (VSCodium + direnv: yes; T3/OpenCode threads: not
  necessarily), so `just`, `alejandra`, `deadnix` may be missing; use the raw
  commands from `justfile` or `nix develop --impure -c <cmd>`. `python3`
  (stdlib only), `jq`, `git`, `rg` are installed system-wide for scripting
  and edits. For other one-off tools prefer `nix shell --inputs-from .
  nixpkgs#<pkg>` (pinned to this flake's nixpkgs, usually already in the
  store). A pull still running after 90 s notifies the user (agent-common hook).
- **Public repo**: never commit secrets, keys, tokens, or personal data.
- **`.repos/`** holds reference clones/submodules (old config, nixos-anywhere,
  …): read-only, excluded from formatting.
- **maple and peacelily are headless**: no GUI features there; keep them out
  of desktop changes.
- Don't commit unless asked; don't touch `.claude/settings.json`.

## Current state (2026-11)

- Known broken: `niri-desktop-vm` and `packages.desktop` (niri wrapper vs
  niri 26.04 / wrappers API), `packages.meshchatx` (insecure pnpm in the
  perSystem pkgs). `eval-all` skips `niri-desktop-vm` (list in `justfile`).
  The niri/hyprland stack is slated for removal.
- `aarch64-linux` was dropped from `systems`; all hosts are x86_64.
- Eval is not in the pre-commit hook (≈1 min); run `just check` manually.

Pointers (`docs/plans/`):
- `2026-11-17-backlog.md` — ordered backlog (repo health, agent tooling, multi-machine)
- `2026-11-17-user-actions.md` — things only the user can do (switch, sops, deploys)
- `2026-11-17-agentic-workspace-design.md` — agent-host/agent-client design + rollout
- `2026-11-17-aesthetics-design.md` — desktop look and theming
- `ARCHITECTURE.md` (repo root) — module-by-module reference
