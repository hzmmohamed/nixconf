# Migration TODO

Migrating from old config (Caramel Mint / Snowfall Lib) at `.repos/old-config/` into this flake-parts repo.

## Infrastructure

- [x] Create butternut host (Intel, ASUS laptop, systemd-boot, LUKS)
- [x] Create devShell for development
- [x] Create VM export for testing
- [x] Change default user to `meshmoss` (single source of truth in `modules/user.nix`)
- [x] Update git config (email: hzmmohamed@gmail.com, name from user.nix)
- [x] Git enhancements (delta diffs, LFS, auto-setup-remote, rebase-on-pull)

## Core Workflow

- [x] Arabic keyboard layout (US + Arabic, XKB switching) — configured in sway module
- [ ] SSH server module (OpenSSH on custom port, or Tailscale SSH — pick one)
- [ ] Tailscale VPN (replace ZeroTier)
- [ ] Secrets management (sops-nix for Syncthing certs, SSH keys, etc.)
- [ ] Syncthing (unified config between hosts, sops-managed certs)
- [ ] GPG + SSH agent integration

## Desktop Essentials

- [x] Sway WM (migrated from old config, hjem config generation, XDG portals, greetd)
- [x] Waybar (replicated from old config with Catppuccin Latte theme, right-side vertical bar)
- [x] Login manager (greetd + tuigreet with session picker on butternut, auto-login on VM)
- [x] Screen lock / idle management (swayidle + swaylock)
- [x] Clipboard history (cliphist + wl-clipboard)
- [x] Blue light filter (gammastep)
- [x] Bitwarden / rbw (password manager CLI)

## Productivity Apps

- [x] Obsidian (note-taking)
- [x] LibreOffice
- [ ] Zotero (reference manager + plugins)
- [x] Typst (document typesetting)
- [x] Element Desktop (Matrix client)

## Development Tools

- [ ] VSCode / VSCodium (with extensions: Python, Go, Nix, Git, Jupyter)
- [x] Docker Compose + lazydocker + dive
- [ ] Kubernetes tools (kubectl, helm, kubectx, k9s, lens, kind, stern, eksctl)
- [ ] AWS tools (aws-vault, awscli2)
- [x] ADB (Android Debug Bridge)
- [ ] Node.js tooling
- [ ] Shell history sync (Atuin)
- [ ] Zellij (terminal multiplexer)

## Shell & Terminal

- [x] Fish aliases/abbreviations (rm/cp/mv interactive, git/k8s/systemctl abbrevs)
- [ ] Starship prompt (or keep custom Fish prompt — decide)
- [ ] Yazi file manager (with image/PDF preview)

## Specialized Suites (as needed)

- [ ] Music production (Ardour, Audacity, Carla, Surge XT, Hydrogen, Yabridge, musnix)
- [ ] AI tools (Ollama + CUDA, Whisper.cpp)
- [ ] CAD / Maker tools (FreeCAD, OpenSCAD)
- [ ] Design tools (Inkscape, Blender, FontForge, Figma)
- [x] Media tools (MPV, VLC, HandBrake, DigiKAM, yt-dlp, ffmpeg, playerctl)

## Settings to Migrate (for existing modules)

- [ ] Firefox extensions (Bitwarden, Tree Style Tab, Zotero connector)
- [x] Additional fonts (Noto CJK, Noto Emoji, Roboto, Victor Mono, FiraCode NF, etc.)
- [x] Touchpad config for laptop hosts (dwt, tap-to-click, middle emulation) — in sway module
- [ ] Doas (sudo replacement) — decide if wanted
- [ ] Polkit configuration

## Host-Specific

- [x] butternut: asusd (ASUS laptop daemon)
- [ ] butternut: nix-serve-ng (binary cache)
- [x] butternut: wayvnc
- [x] butternut: nix-ld with libraries
- [ ] Desktop vs CLI-only toggle (module to disable desktop entirely)
