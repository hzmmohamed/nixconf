# Architecture

This is a NixOS configuration for multiple hosts, built on
[flake-parts](https://github.com/hercules-ci/flake-parts) with
[import-tree](https://github.com/vic/import-tree) for automatic module
discovery. Every `.nix` file under `modules/` is a flake-parts module.

## How it works

```
flake.nix
    |
    +--> imports all of modules/ via import-tree
              |
              +--> modules/user.nix          (flake.user — single source of truth for username)
              +--> modules/theme.nix         (flake.theme — color palette, accessible everywhere)
              +--> modules/flake-parts.nix   (systems, custom flake options)
              |
              +--> modules/nixos/base/       (option declarations: user, keymap, monitors, autostart, persistence)
              +--> modules/nixos/features/   (composable NixOS modules: desktop, sway, gaming, ...)
              +--> modules/nixos/extra/      (integration layers: home-manager bridge, theme switch, impermanence)
              +--> modules/nixos/hosts/      (per-host configurations)
              |
              +--> modules/vms/             (purpose-built test VMs)
              +--> modules/wrappedPrograms/  (per-system packages built with the wrappers library)
```

**Key idea:** NixOS modules (`flake.nixosModules.*`) define system configuration.
Wrapped programs (`perSystem.packages.*`) are standalone packages with baked-in
config. Hosts compose both.

## Module layers

### `modules/` — top-level

| File | Exports | Purpose |
|------|---------|---------|
| `user.nix` | `flake.user` | Username and home path. Change it here, it cascades everywhere. |
| `theme.nix` | `flake.palettes`, `flake.fonts`, `flake.color`, `flake.theme`, `flake.catppuccin`, `flake.catppuccinMocha` | Palettes (Catppuccin Latte/Mocha `{light,dark}` consumed via `preferences.theme.palette`; legacy Gruvbox `theme` for the niri wrappers) and fonts. |
| `flake-parts.nix` | systems (x86_64-linux), options | Declares mergeable flake options (`wrapperModules`, `diskoConfigurations`). |
| `devshell.nix` | `perSystem.devShells.default`, treefmt | devenv shell (`nix develop --impure`) with nix tooling, sops, age, just, claude-code; alejandra + deadnix git hooks. |
| `checks.nix` | `perSystem.checks.<host>-eval` | Eval-only check per nixosConfiguration (`just eval-all` is the fast equivalent). |

### `modules/nixos/base/` — option declarations

These files all contribute to `flake.nixosModules.base`. They define the
`preferences.*` and `persistance.*` option schemas that feature modules read.

| File | Options defined |
|------|-----------------|
| `user.nix` | `preferences.user.{name, passwordFromSops}` (default name: `self.user.name`) |
| `keymap.nix` | `preferences.keymap` (nested keybinding tree with chord support) |
| `monitors.nix` | `preferences.monitors` (width, height, refresh, position per output) |
| `start.nix` | `preferences.autostart` (list of packages/commands to exec at login) |
| `persistance.nix` | `persistance.{enable, data, cache, directories, files}` |
| `keyboard.nix` | `preferences.keyboard.{layouts, toggle, extraOptions}` |
| `theme.nix` | `preferences.theme.{source, palette, stateDir, files, dconf, reloadHooks}` |
| `desktop-shell.nix` | `preferences.desktopShell` (`waybar` \| `noctalia`, Sway hosts) |
| `profile.nix` | `preferences.desktop.enable` (set by `desktop`; gates GUI bits in always-imported modules) |

### `modules/nixos/features/` — composable feature modules

Each file exports one `flake.nixosModules.<name>`. Hosts pick which ones to import.

| Module | What it does | Imports |
|--------|-------------|---------|
| `general` | Creates user, sets shell, persistence dirs | `extra_hjem`, `extra_theme`, `fish`, `gtk` (inactive unless `preferences.desktop.enable`), `nix` |
| `desktop` | WM-agnostic desktop base, sets `preferences.desktop.enable`: fonts, polkit, bluetooth, graphics, pipewire, browsers, VT switching disabled (NAutoVTs=0) | `gtk`, `wallpaper`, `pipewire`, `firefox`, `chromium` |
| `sway` | Sway WM: keybinds, input (US+Arabic), gaps, brightness, XDG portals (wlr+gtk), env import for systemd/dbus | `wofi-theme` |
| `hyprland` | Hyprland WM: keybinds, animations, monitors, dwindle layout | (home-manager `wayland.windowManager.hyprland`; unused, slated for removal) |
| `waybar` | Right-side vertical status bar with Catppuccin Latte theme: rotated clock, persistent workspaces, expandable CPU/mem/temp drawer, battery | |
| `swayidle` | Screen lock (swaylock-effects with blur, clock, Catppuccin Mocha theme) + idle timeout (5min lock, 10min DPMS off) | |
| `clipse` | Clipboard history (clipse); unused, slated for removal | |
| `gammastep` | Blue light filter (Cairo coordinates) | |
| `gaming` | Steam, Lutris, Heroic, Proton GE, DXVK, MangoHUD | |
| `vr` | WiVRn, OpenXR, xrizer, OpenVR paths | |
| `pipewire` | Audio: PipeWire + ALSA + PulseAudio + JACK + DeepFilter | |
| `powersave` | power-profiles-daemon, thermald, LACT for AMD GPU | |
| `impermanence` | Ephemeral root with btrfs + tmpfs | `extra_impermanence` |
| `firefox` | Firefox with persistence | |
| `chromium` | Ungoogled Chromium | |
| `discord` | Vesktop + Discord | |
| `telegram` | Telegram Desktop | |
| `youtube-music` | YouTube Music client | |
| `gimp` | GIMP 3 | |
| `gtk` | adw-gtk3 + Papirus recoloured from the palette, light/dark via `theme-mode`; gated on `preferences.desktop.enable` | |
| `nix` | direnv, nix-index, flakes, nix-ld, formatters, cuda-maintainers cachix | |
| `wallpaper` | swww daemon with wallpaper image (used by sway/hyprland; niri uses noctalia wallpaper management) | |
| `sops` | Enables sops-nix with age key path | `inputs.sops-nix` |
| `syncthing` | Syncthing service with device IDs, reads certs from sops secrets | |
| `shared-zotero` | Zotero + Syncthing folders + sops secrets (see below) | |
| `rbw` | Bitwarden CLI (rbw) with pinentry (kept during the move to `vault`) | |
| `vault` | KeePassXC vault in a Syncthing folder (`~/Vault`) shared with phone/hosts; KeePassXC GUI + config on desktops, folder only on headless hosts (`preferences.vault.*`) | |
| `office` | Obsidian, LibreOffice, Typst, Element Desktop, zathura | |
| `docker` | Docker daemon + compose + lazydocker + dive | |
| `media` | MPV, VLC, HandBrake, DigiKAM, yt-dlp, ffmpeg, playerctl | |
| `adb` | Android Debug Bridge | |
| `tailscale` | Tailscale VPN with SSH, firewall rules, system tray (desktop hosts only) | |
| `vscode` | VSCodium with extensions (Nix, Python, GitLab, Claude Code), Catppuccin theme, gnome-keyring integration | |
| `k8s` | kubectl, helm, kubectx, k9s, kind, stern, eksctl | |
| `aws` | AWS CLI + aws-vault | |
| `atuin` | Shell history sync with vim keybindings, config via home-manager | |
| `zellij` | Terminal multiplexer | |
| `yazi` | File manager with image/PDF preview, config via home-manager | |
| `design` | Inkscape, Blender, FontForge, font-manager | |
| `niri-desktop` | Niri + Noctalia shell: wrapped niri config via NIRI_CONFIG env, noctalia-shell as systemd user service (Restart=always), wallpaper via noctalia | |
| `doas` | Replaces sudo with doas (passwordless, keepEnv) | |
| `gpg` | GnuPG agent with SSH support, pinentry | |
| `nodejs` | Node.js, npm, pnpm | |
| `cad` | FreeCAD, OpenSCAD | |
| `ai` | Ollama service, whisper-cpp | |
| `ai-server` | llama-swap (via upstream llama.cpp flake with CUDA), Wyoming STT/TTS/wakeword, Qdrant, LibreChat | |
| `email` | OAuth2 email (Gmail/O365), Thunderbird, aerc TUI, imapnotify desktop notifications, gnome-keyring, PAM integration | |
| `openrgb` | OpenRGB service + GUI for hardware RGB lighting | |
| `reticulum` | Reticulum mesh networking, MeshChat launchers | `inputs.reticulum-flake` |
| `music` | Ardour, Audacity, Carla, Surge XT, Hydrogen, Yabridge, plugin paths | |
| `agent-common` (`agent-env.nix` part) | Network-aware agent tooling: `agent-net` (metered/unmetered/offline from NetworkManager, override via `agent-net set`; Claude SessionStart/UserPromptSubmit hooks), `nx` (store-first tool runner that refuses big downloads/builds on metered links), `agent-devshell` (starts T3's Claude/OpenCode inside the project's cached direnv dev shell, never fails closed), shared guidelines at `~/.config/agents/guidelines.md` (Claude `CLAUDE.md` import line, OpenCode `instructions`). Options: `preferences.agents.claudeHooks` (extra Claude Code hook commands per event, appended to the built-in ones), `preferences.agents.guidelinesFile` (read-only store path). Unit tests run as `checks.agent-env` | |
| `cable-link` | Ethernet between the laptops: `lan` (DHCP) falls through to a static `cable` link; manual `<me>-shares`/`<peer>-shares` internet sharing. `preferences.cable.peerSharesMetered` marks `<peer>-shares` metered (NM `metered=1`) so `agent-net` sees a carried peer's hotspot | |

### `modules/nixos/extra/` — integration layers

| File | Exports | Purpose |
|------|---------|---------|
| `hjem/hjem.nix` | `nixosModules.extra_hjem` | Home-manager bridge (despite the name): imports `home-manager.nixosModules.home-manager` + catppuccin modules, sets up `home-manager.users.<user>` |
| `theme.nix` | `nixosModules.extra_theme` | Implements `preferences.theme.*`: per-mode palette files under `~/.local/state/theme`, `theme-mode light|dark` switch (driven by darkman) |
| `impermanence.nix` | `nixosModules.extra_impermanence` | Btrfs subvolume setup, old root cleanup, `/persist` mounts |

### `modules/nixos/hosts/` — host configurations

Each host directory has `configuration.nix` (imports + host-specific config),
`hardware-configuration.nix` (auto-generated hardware), and optionally `disko.nix`
(disk layout).

| Host | WM | Hardware | Notable features |
|------|----|----------|------------------|
| **butternut** | Sway | ASUS TUF (Intel Alder Lake + RTX 3050), LUKS ext4 | Laptop used as a desktop (broken panel, external monitor, always on AC). NVIDIA PRIME offload with the dGPU kept awake for CUDA, LTS kernel. Split files: `gpu.nix`, `power.nix`, `audio.nix`, `games.nix`, `network.nix`. Home build server for hazel (`nix-builder`: `nix-ssh` via nix.sshServe) and binary cache (nix-serve/harmonia). greetd, email, reticulum, openrgb, gaming |
| **hazel** | Sway | ThinkPad E14 Gen 2 (i5-1135G7), LUKS NVMe | **Primary device**, carried; 256 GB disk, so builds go to butternut (`nix-builder` client, `deploy` plans the build location). greetd, battery notifications, lan-cache client, remote-deploy |
| **maple** | None (headless) | Intel laptop, dead screen, LUKS ext4 | Always-on node: SSH, Tailscale, syncthing, nix-serve, docker/k8s CLI. Lid switch ignored, sleep targets disabled, user lingering, journald capped |
| **peacelily** | None (headless) | Intel, NVIDIA GPU | AI server: llama-swap, Wyoming STT/TTS, Qdrant, LibreChat. Not yet redeployed with the current config. Deployed via nixos-anywhere (`scripts/install-host.sh peacelily <ip>`) |

**Switching WMs:** Hosts choose their window manager by importing one line:
```nix
self.nixosModules.sway          # Sway (+ waybar or noctalia via preferences.desktopShell)
self.nixosModules.niri-desktop  # Niri + Noctalia (currently broken, unused)
```

### `modules/vms/` — test VMs

Purpose-built QEMU VMs for testing specific aspects. Each VM includes
only the modules needed for its test — not a replica of any host.

| File | nixosConfiguration | Purpose |
|------|-------------------|---------|
| `desktop-test.nix` | `desktop-vm` | Sway + waybar + desktop essentials. Auto-login, no secrets. |
| `niri-desktop-test.nix` | `niri-desktop-vm` | Niri + Noctalia desktop. Requires `QEMU_OPTS="-device virtio-vga-gl -display gtk,gl=on"` for GPU acceleration (niri needs DRM/KMS, bochs VGA won't work). |

Network test VMs (butternut+maple pair for syncthing/tailscale/SSH) will
be added as separate files when needed.

### `modules/wrappedPrograms/` — standalone packages

These use the [wrappers](https://github.com/Lassulus/wrappers) and
[wrapper-modules](https://github.com/BirdeeHub/nix-wrapper-modules) libraries
to create packages with baked-in configuration. They export `perSystem.packages.*`
and optionally `flake.wrapperModules.*`.

| Module | Packages | What it wraps |
|--------|----------|---------------|
| `environment.nix` | `desktop`, `terminal`, `environment` | Niri+Kitty+Fish bundle with ~30 runtime tools |
| `fish.nix` | `fish` | Fish shell with prompt, zoxide, direnv, vi keys |
| `kitty.nix` | `kitty` | Kitty terminal; colours from `~/.local/state/theme/current/kitty.conf` (palette, light/dark), cursor trail |
| `neovim/` | `neovim`, `neovimDynamic`, `devMode` | Neovim with LSP, treesitter, blink-cmp, custom VJXL language |
| `niri.nix` | `niri` | Niri compositor with keybinds, which-key menus, hotkeys help (Mod+Shift+?), default terminal from wrapped package |
| `noctalia/` | `noctalia-shell` | Desktop shell: bar, launcher, notifications, OSD, screen recorder, wallpaper management |
| `git.nix` | `git` | Git with author name/email from `self.user` |
| `jj.nix` | `jujutsu`, `jjui` | Jujutsu VCS + TUI with user config |
| `nh.nix` | `nh` | Nix helper with flake path |
| `lf.nix` | `lf` | File manager with shortcuts and preview |
| `qalc.nix` | `qalc` | Calculator |
| `wlr-which-key/` | (library) | Which-key menu generator, used by niri |
| `quickshell/` | `quickshellWrapped` | Quickshell with zoxide |

### `secrets/` — encrypted secrets

Secrets are managed with [sops-nix](https://github.com/Mic92/sops-nix) and
age encryption. The private key lives at `~/.config/sops/age/keys.txt` on
each host (not in the repo).

```
secrets/
├── README.md               (documents each file and its usage)
├── atuin.yaml              (atuin sync key)
├── shared/                 (librechat, tailscale auth key, home Wi-Fi)
├── butternut/              (syncthing, nix-serve)
├── hazel/                  (syncthing)
├── maple/                  (syncthing, nix-serve)
└── <hostname>/
    └── <service>.yaml
```

Convention: `secrets/<hostname>/<service>.yaml`. The `.sops.yaml` at the repo
root matches `secrets/**/*.yaml` with the primary age key.

### Shared feature pattern: `shared-zotero.nix`

Some features need cross-host infrastructure (syncthing, sops secrets) to
work. Rather than scattering this wiring across host configs, the feature
module owns it all.

```
shared-zotero.nix
    |
    +--> installs Zotero
    +--> reads config.networking.hostName → "butternut"
    +--> declares sops.secrets from secrets/butternut/syncthing.yaml
    +--> declares syncthing folders (zotero-db, zotero-attachments)
```

**How it resolves per-host:** The module constructs the sopsFile path
dynamically from `config.networking.hostName`:

```nix
secretsFile = ../../.. + "/secrets/${hostname}/syncthing.yaml";
```

Each host has its own encrypted file with its own syncthing cert/key. The
module doesn't know or care which host it's on — it just follows the naming
convention.

**To add a new host to the Zotero share:**
1. Create `secrets/<hostname>/syncthing.yaml` with that host's syncthing
   cert/key (use `sops` to encrypt)
2. Import `shared-zotero`, `syncthing`, and `sops` in the host config
3. Done — the module wires everything from the hostname

**To disable sharing** (Zotero without sync):
```nix
preferences.zotero.sharing = false;
```

This pattern can be reused for other shared resources that need per-host
secrets and syncthing folders.

### `scripts/` — deployment automation

| Script | Purpose |
|--------|---------|
| `install-host.sh` | nixos-anywhere install for any host: `install-host.sh <hostname> <ip>`. Copies the age key, supports `--cache` (local nix-serve), `--mount-only` and `--luks-password`. |

### External flake inputs

| Input | Purpose | Used by |
|-------|---------|---------|
| `llama-cpp` (`ggml-org/llama.cpp`) | Upstream llama.cpp with CUDA package | `ai-server` (`.packages.${system}.cuda`) |
| `reticulum-flake` | Reticulum mesh networking overlays and modules | `reticulum` |
| `catppuccin` | Catppuccin theming for NixOS/home-manager | `extra_hjem` |
| `sops-nix` | Secret management with age encryption | `sops`, `ai-server`, `email`, `syncthing` |

## Data flow: how a host configuration is built

```
1. flake.nix calls mkFlake with import-tree ./modules
2. import-tree discovers all .nix files → they become flake-parts modules
3. A host (e.g., butternut) defines:
     flake.nixosConfigurations.butternut = nixpkgs.lib.nixosSystem {
       modules = [ self.nixosModules.hostButternut ];
     };
4. hostButternut imports: base → general → desktop → sway → [feature modules]
5. base defines preferences.* options
6. general creates the user, imports the home-manager bridge (extra_hjem) and extra_theme
7. desktop sets up fonts, hardware, browsers (WM-agnostic)
8. sway configures the WM (programs.sway + home-manager)
9. feature modules register palette files via preferences.theme.files
10. Wrapped packages (terminal, fish, git, neovim, ...) are
    referenced by general.nix as the user's shell
```

## Invariants

- **One username, one place.** `modules/user.nix` defines `flake.user`. NixOS
  modules get it via `config.preferences.user.name`. Wrapped programs get it via
  `self.user`. Never hardcode a username.

- **Themes live in one place.** `modules/theme.nix` defines the palettes;
  NixOS modules read colours from `config.preferences.theme.palette.{light,dark}`
  (wrapped programs may use the flake-level attrs). Never hardcode hex values.

- **Feature modules are independent.** A feature module should not import another
  feature module (except `desktop` which aggregates shared desktop basics). Hosts
  compose features.

- **desktop.nix is WM-agnostic.** It provides fonts, hardware, polkit, browsers.
  Window managers (sway, hyprland, niri) are separate modules chosen per-host.

- **Wrapped programs don't access NixOS config.** They're `perSystem` packages.
  They read `self.user` and `self.theme` from flake-level attrs, not from
  `config.preferences.*`.

- **home-manager, not hjem.** User-level config uses home-manager
  (`home-manager.users.<name>`). The `extra_hjem` module name is historical.

- **Features own their infrastructure.** When a feature needs syncthing
  folders or sops secrets, it declares them itself (like `shared-zotero.nix`
  does). Host configs should not contain syncthing folder definitions or
  sops secret declarations that belong to a feature.

- **Secrets follow `secrets/<hostname>/`** convention. Feature modules
  resolve the right file via `config.networking.hostName`. Never hardcode
  a hostname in a sopsFile path.

- **Files must be git-tracked.** Nix flakes only see git-tracked files. New
  modules must be `git add`'ed before they're visible to `nix build`/`nix eval`.
