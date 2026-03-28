# Migration TODO

Migrating from old config (Caramel Mint / Snowfall Lib) at `.repos/old-config/` into this flake-parts repo.

## Infrastructure

- [x] Create butternut host (Intel, ASUS laptop, systemd-boot, LUKS)
- [x] Create devShell for development
- [x] Create VM export for testing
- [x] Change default user to `meshmoss` (single source of truth in `modules/user.nix`)
- [x] Update git config (email: hzmmohamed@gmail.com, name from user.nix)
- [ ] Git enhancements (delta diffs, LFS, auto-setup-remote, rebase-on-pull)

## Core Workflow

- [x] Arabic keyboard layout (US + Arabic, XKB switching) — configured in sway module
- [ ] SSH server module (OpenSSH on custom port, or Tailscale SSH — pick one)
- [ ] Tailscale VPN (replace ZeroTier)
- [ ] Secrets management (sops-nix for Syncthing certs, SSH keys, etc.)
- [ ] Syncthing (unified config between hosts, sops-managed certs)
- [ ] GPG + SSH agent integration

## Desktop Essentials

- [x] Sway WM (migrated from old config, with waybar, hjem config generation)
- [x] Screen lock / idle management (swayidle + swaylock)
- [x] Clipboard history (cliphist + wl-clipboard)
- [x] Blue light filter (gammastep)
- [ ] Bitwarden / rbw (password manager CLI + browser extensions)

## Productivity Apps

- [ ] Obsidian (note-taking)
- [ ] LibreOffice
- [ ] Zotero (reference manager + plugins)
- [ ] Typst (document typesetting)
- [ ] Element Desktop (Matrix client)

## Development Tools

- [ ] VSCode / VSCodium (with extensions: Python, Go, Nix, Git, Jupyter)
- [ ] Docker Compose + lazydocker + dive
- [ ] Kubernetes tools (kubectl, helm, kubectx, k9s, lens, kind, stern, eksctl)
- [ ] AWS tools (aws-vault, awscli2)
- [ ] ADB (Android Debug Bridge)
- [ ] Node.js tooling
- [ ] Shell history sync (Atuin)
- [ ] Zellij (terminal multiplexer)

## Shell & Terminal

- [ ] Fish aliases/abbreviations (rm/cp/mv interactive, git/k8s/systemctl abbrevs)
- [ ] Starship prompt (or keep custom Fish prompt — decide)
- [ ] Yazi file manager (with image/PDF preview)

## Specialized Suites (as needed)

- [ ] Music production (Ardour, Audacity, Carla, Surge XT, Hydrogen, Yabridge, musnix)
- [ ] AI tools (Ollama + CUDA, Whisper.cpp)
- [ ] CAD / Maker tools (FreeCAD, OpenSCAD)
- [ ] Design tools (Inkscape, Blender, FontForge, Figma)
- [ ] Media tools (MPV, VLC, HandBrake, DigiKAM)

## Settings to Migrate (for existing modules)

- [ ] Firefox extensions (Bitwarden, Tree Style Tab, Zotero connector)
- [ ] Additional fonts (Noto CJK, Noto Emoji, Roboto, Victor Mono)
- [x] Touchpad config for laptop hosts (dwt, tap-to-click, middle emulation) — in sway module
- [ ] Doas (sudo replacement) — decide if wanted
- [ ] Polkit configuration

## Host-Specific

- [ ] butternut: asusd (ASUS laptop daemon)
- [ ] butternut: nix-serve-ng (binary cache)
- [ ] butternut: wayvnc
- [ ] butternut: nix-ld with libraries
- [ ] Desktop vs CLI-only toggle (module to disable desktop entirely)
