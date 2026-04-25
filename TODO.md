# Migration TODO

Migrating from old config (Caramel Mint / Snowfall Lib) at `.repos/old-config/` into this flake-parts repo.

## Infrastructure

- [x] Create butternut host (Intel, ASUS laptop, systemd-boot, LUKS)
- [x] Create hazel host (ThinkPad E14 Gen 2, systemd-boot, LUKS NVMe)
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
- [ ] KDE Connect
- [ ] Fix activity-watcher-window unknown window names
- [ ] Fix links (from zotero and others) opening in vscode
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
- [x] hazel: ThinkPad E14 Gen 2 host config (Sway, programming-focused, LUKS NVMe)
- [ ] Desktop vs CLI-only toggle (module to disable desktop entirely)
- [ ] Neovim Catppuccin colorscheme + darkman integration (Latte/Mocha switching)
- [ ] Ungoogled Chromium extension support (see https://gist.github.com/MaximilianGaedig/acbce27522c997e9666bd93cef77492d)
- [x] Email setup: Thunderbird GUI with OAuth2 + gnome-keyring PAM integration
- [ ] aerc TUI email client with xoauth2 — BROKEN: custom OAuth2 flow fails (Google: "invalid client", Outlook: redirect works but token exchange unreliable). Fix approach: extract refresh tokens from Thunderbird's saved passwords (Settings > Privacy & Security > Saved Passwords, look for "oauth://") and use aerc's native `imapOauth2Params`/`smtpOauth2Params` with Thunderbird's client_id `9e5f94bc-e8a4-4e73-b8be-63364c29d753` (no client_secret needed). Store refresh tokens in sops secret, passwordCommand reads from `config.sops.secrets.*.path`. Remove custom `email-oauth2` script and gnome-keyring dependency for email. Reference config: https://codeberg.org/eisfunke/funke-nixos/src/branch/main/home/modules/mail.nix
- [ ] Email notifications (imapnotify) — BROKEN: depends on above OAuth2 fix. imapnotify `passwordCmd` needs a working token. Once aerc OAuth2 is fixed, imapnotify can use the same sops-backed passwordCommand. Also set `services.imapnotify.path` for any runtime deps.
- [ ] Media player widget (waybar/sway) integrated with Spotify (playerctl/MPRIS)
- [x] Global speech-to-text tool (OpenWhisper / whisper.cpp), system-wide hotkey activation
- [x] Add TTS (Kokoro) + STT (Wyoming Whisper) to LibreChat in ai-server (WIP)
- [ ] Verify Wyoming Faster Whisper exposes HTTP /v1/audio/transcriptions (or add bridge)
- [ ] Configure fan control to make peacelily quieter when idle
- [ ] Make peacelily RGB profiles dynamic based on state (idle, generating tokens, etc.)
- [ ] Set default email client to Thunderbird and configure default send-from address
- [ ] Configure Claude Code to send notification on intervention/stop
- [ ] Make meshchat run as a distinct user with exclusive write access to its files
- [ ] Live audio transcription of main output (see https://github.com/basnijholt/agent-cli/blob/main/docs/commands/transcribe-live.md)

## AI: Resilient Multi-Device Setup

Goal: seamless AI experience that degrades gracefully when peacelily is unreachable, rather than failing entirely.

- [ ] Run LibreChat on butternut (laptop) instead of / in addition to peacelily
  - [ ] Configure LibreChat to prefer peacelily endpoint when reachable (via Tailscale)
  - [ ] Fall back to a small local model (e.g. via Ollama on butternut) when offline
  - [ ] Conversation sync between butternut and peacelily (shared MongoDB or export/import)
- [ ] Run a small local model on butternut for offline use (Ollama or llama-swap)
- [ ] Shared memory/context database synced across devices (Qdrant via Syncthing, or hosted on peacelily with local replica)

## AI: Knowledge & Notes Sync

Goal: capture notes, ideas, and memories on any device and have them available everywhere.

- [ ] Notes sync: phone → laptop → peacelily (Syncthing-based, compatible with Obsidian mobile)
- [ ] Unified memory store: structured notes/memories accessible from LibreChat and CLI tools
- [ ] Investigate open-source personal knowledge tools (Logseq, Obsidian Sync alternative, etc.)

## AI: Agentic Workflows

Goal: move from chat to autonomous task execution with tool use.

- [ ] Web search in LibreChat (SearXNG — WIP, needs ai-search sops secret)
- [ ] Code execution sandbox (LibreChat code interpreter plugin or isolated container)
- [ ] Agentic framework integration (browser-use, or similar)
- [ ] Configure claude-code / opencode to use peacelily as the LLM backend
- [ ] Investigate: Lobe Hub, Gobii Platform (https://github.com/gobii-ai/gobii-platform)

## Peacelily: Vision Model

- [ ] Add vision model to llama-swap (qwen2.5-vl or qwen3-vl)
- [ ] Expose vision model in LibreChat endpoint

- Pacakge https://github.com/dgr8akki/nano-ffmpeg