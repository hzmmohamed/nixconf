# Migration TODO

Migrating from old config (Caramel Mint / Snowfall Lib) at `.repos/old-config/` into this flake-parts repo.

## Infrastructure

- [x] Create butternut host (Intel, ASUS laptop, systemd-boot, LUKS)
- [x] Create devShell for development
- [x] Create VM export for testing
- [x] Change default user to `hfahmi` (single source of truth in `modules/user.nix`)
- [x] Update git config (email: hzmmohamed@gmail.com, name from user.nix)
- [x] Git enhancements (delta diffs, LFS, auto-setup-remote, rebase-on-pull)

## Core Workflow

- [x] Arabic keyboard layout (US + Arabic, XKB switching) — configured in sway module
- [x] SSH server module (OpenSSH on port 7654, already in butternut)
- [x] Tailscale VPN with SSH
- [x] Tailscale auth keys for automatic login (especially on peacelily)
- [x] Secrets management (sops-nix, age encryption, centralized in `secrets/`)
- [x] Syncthing (device IDs, sops-managed certs, folders owned by feature modules)
- [x] GPG + SSH agent integration

## Desktop Essentials

- [x] Sway WM (migrated from old config, hjem config generation, XDG portals, greetd)
- [x] Waybar (replicated from old config with Catppuccin Latte theme, right-side vertical bar)
- [x] Login manager (greetd + tuigreet with session picker on butternut, auto-login on VM)
- [x] Screen lock / idle management (swayidle + swaylock)
- [x] Clipboard history (clipse, systemd service with Catppuccin theme)
- [x] Blue light filter (gammastep) — BUG: geoclue error, using manual lat/lng as workaround
- [x] Bitwarden / rbw (password manager CLI)
- [x] Notification daemon (mako, sway-compatible, Catppuccin themed)
- [x] Bluetooth controls (blueman + nm-applet)
- [ ] PulseAudio volume control (pavucontrol)
- [x] swww + wallpaper switcher (swww + waypaper, autostart via preferences.autostart)
- [x] Darkman light/dark mode switching (Catppuccin Latte/Mocha, auto by time + Mod4+Shift+t toggle) — BUG: GTK theme not switching (dconf write may not be picked up by running apps)
- [x] Bibata cursor theme (opt-in module)
- [x] Wofi Catppuccin theming (light/dark via darkman symlink swap)
- [x] Wofi emoji picker (custom wrapper with larger font)

## Productivity Apps

- [x] Obsidian (note-taking)
- [x] LibreOffice
- [x] Zotero (reference manager, synced via Syncthing)
- [x] Typst (document typesetting)
- [x] Element Desktop (Matrix client)

## Development Tools

- [x] VSCode / VSCodium (with extensions, Catppuccin theme, mutable settings.json for darkman)
- [x] Docker Compose + lazydocker + dive
- [x] Kubernetes tools (kubectl, helm, kubectx, k9s, kind, stern, eksctl)
- [x] AWS tools (aws-vault, awscli2)
- [x] ADB (Android Debug Bridge)
- [x] Node.js tooling (nodejs, npm, pnpm)
- [x] Shell history sync (Atuin)
- [x] Zellij (terminal multiplexer)

## Shell & Terminal

- [x] Fish aliases/abbreviations (rm/cp/mv interactive, git/k8s/systemctl abbrevs)
- [x] Starship prompt (integrated into fish wrapper)
- [x] Yazi file manager (with image/PDF preview, TOML config via hjem)

## Specialized Suites (as needed)

- [x] Music production (Ardour, Audacity, Carla, Surge XT, Hydrogen, Yabridge, plugin paths)
- [x] AI tools (Ollama, Whisper.cpp)
- [x] CAD / Maker tools (FreeCAD, OpenSCAD)
- [x] Design tools (Inkscape, Blender, FontForge, font-manager)
- [x] Media tools (MPV, VLC, HandBrake, DigiKAM, yt-dlp, ffmpeg, playerctl)

## Settings to Migrate (for existing modules)

- [ ] Firefox extensions (Bitwarden, Tree Style Tab, Zotero connector)
- [x] Additional fonts (Noto CJK, Noto Emoji, Roboto, Victor Mono, FiraCode NF, etc.)
- [x] Touchpad config for laptop hosts (dwt, tap-to-click, middle emulation) — in sway module
- [x] Doas (sudo replacement, passwordless, keepEnv, `sudo` aliased to `doas`)
- [x] Polkit (already in desktop.nix)

## Host-Specific

- [x] butternut: asusd (ASUS laptop daemon)
- [x] butternut: nix-serve-ng (binary cache)
- [x] butternut: wayvnc
- [x] butternut: nix-ld with libraries
- [ ] Desktop vs CLI-only toggle (module to disable desktop entirely)
- [ ] Neovim Catppuccin colorscheme + darkman integration (Latte/Mocha switching)
