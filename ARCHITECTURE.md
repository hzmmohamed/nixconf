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
              +--> modules/nixos/extra/      (integration layers: hjem, impermanence)
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
| `theme.nix` | `flake.theme`, `flake.themeNoHash`, `flake.catppuccin` | Color palettes: Gruvbox (niri/hyprland desktop), Catppuccin Latte (sway desktop). |
| `flake-parts.nix` | systems, options | Declares mergeable flake options (`wrapperModules`, `diskoConfigurations`). |
| `devshell.nix` | `perSystem.devShells.default` | `nix develop` shell with nix tooling, sops, age, claude-code-bun. |

### `modules/nixos/base/` — option declarations

These files all contribute to `flake.nixosModules.base`. They define the
`preferences.*` and `persistance.*` option schemas that feature modules read.

| File | Options defined |
|------|-----------------|
| `user.nix` | `preferences.user.name` (default: `self.user.name`) |
| `keymap.nix` | `preferences.keymap` (nested keybinding tree with chord support) |
| `monitors.nix` | `preferences.monitors` (width, height, refresh, position per output) |
| `start.nix` | `preferences.autostart` (list of packages/commands to exec at login) |
| `persistance.nix` | `persistance.{enable, data, cache, directories, files}` |

### `modules/nixos/features/` — composable feature modules

Each file exports one `flake.nixosModules.<name>`. Hosts pick which ones to import.

| Module | What it does | Imports |
|--------|-------------|---------|
| `general` | Creates user, sets shell, persistence dirs | `extra_hjem`, `gtk`, `nix` |
| `desktop` | WM-agnostic desktop base: fonts, polkit, bluetooth, graphics, pipewire, browsers, VT switching disabled (NAutoVTs=0) | `gtk`, `wallpaper`, `pipewire`, `firefox`, `chromium` |
| `sway` | Sway WM: keybinds, input (US+Arabic), gaps, brightness, XDG portals (wlr+gtk), env import for systemd/dbus | `extra_hjem_sway` |
| `hyprland` | Hyprland WM: keybinds, animations, monitors, dwindle layout | (uses `home.programs.hyprland` consumed by hjem) |
| `waybar` | Right-side vertical status bar with Catppuccin Latte theme: rotated clock, persistent workspaces, expandable CPU/mem/temp drawer, battery | |
| `swayidle` | Screen lock (swaylock) + idle timeout (5min lock, 10min DPMS off) | |
| `cliphist` | Clipboard history daemon (wl-paste + cliphist) | |
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
| `gtk` | GTK/icon theme (Gruvbox) | |
| `nix` | direnv, nix-index, flakes, nix-ld, formatters | |
| `wallpaper` | swww daemon with wallpaper image (used by sway/hyprland; niri uses noctalia wallpaper management) | |
| `sops` | Enables sops-nix with age key path | `inputs.sops-nix` |
| `syncthing` | Syncthing service with device IDs, reads certs from sops secrets | |
| `shared-zotero` | Zotero + Syncthing folders + sops secrets (see below) | |
| `rbw` | Bitwarden CLI (rbw) with pinentry | |
| `office` | Obsidian, LibreOffice, Typst, Element Desktop, zathura | |
| `docker` | Docker daemon + compose + lazydocker + dive | |
| `media` | MPV, VLC, HandBrake, DigiKAM, yt-dlp, ffmpeg, playerctl | |
| `adb` | Android Debug Bridge | |
| `tailscale` | Tailscale VPN with SSH, firewall rules | |
| `vscode` | VSCodium with extensions, Catppuccin theme, settings via hjem | |
| `k8s` | kubectl, helm, kubectx, k9s, kind, stern, eksctl | |
| `aws` | AWS CLI + aws-vault | |
| `atuin` | Shell history sync with vim keybindings, config via hjem | |
| `zellij` | Terminal multiplexer | |
| `yazi` | File manager with image/PDF preview, config via hjem | |
| `design` | Inkscape, Blender, FontForge, font-manager | |
| `niri-desktop` | Niri + Noctalia shell: wrapped niri config via NIRI_CONFIG env, noctalia-shell as systemd user service (Restart=always), wallpaper via noctalia | |
| `doas` | Replaces sudo with doas (passwordless, keepEnv) | |
| `gpg` | GnuPG agent with SSH support, pinentry | |
| `nodejs` | Node.js, npm, pnpm | |
| `cad` | FreeCAD, OpenSCAD | |
| `ai` | Ollama service, whisper-cpp | |
| `music` | Ardour, Audacity, Carla, Surge XT, Hydrogen, Yabridge, plugin paths | |

### `modules/nixos/extra/` — integration layers

| File | Exports | Purpose |
|------|---------|---------|
| `hjem/hjem.nix` | `nixosModules.extra_hjem` | Configures hjem (home file manager) for the user |
| `hjem/hyprland.nix` | `nixosModules.extra_hjem` | Converts `home.programs.hyprland.settings` + `preferences.keymap` to `~/.config/hypr/hyprland.conf` |
| `hjem/sway.nix` | `nixosModules.extra_hjem_sway` | Converts `home.programs.sway.settings` + `preferences.autostart` to `~/.config/sway/config` |
| `impermanence.nix` | `nixosModules.extra_impermanence` | Btrfs subvolume setup, old root cleanup, `/persist` mounts |

### `modules/nixos/hosts/` — host configurations

Each host directory has `configuration.nix` (imports + host-specific config),
`hardware-configuration.nix` (auto-generated hardware), and optionally `disko.nix`
(disk layout).

| Host | WM | Hardware | Notable features |
|------|----|----------|------------------|
| **main** | Hyprland + Niri | AMD CPU/GPU, NVMe, btrfs | Gaming, VR, impermanence, WiFi hotspot, OBS |
| **mini** | Hyprland + Niri | Intel, ext4 | Lightweight laptop, no VR or impermanence |
| **butternut** | Sway | Intel i915, LUKS ext4 | ASUS laptop, SSH server, asusd, WayVNC, greetd+tuigreet |
| **maple** | Niri + Noctalia | Intel, LUKS ext4 | Workstation, SSH server, nix-serve-ng |

**Switching WMs:** Hosts choose their window manager by importing one line:
```nix
self.nixosModules.sway          # Sway + waybar (Catppuccin)
self.nixosModules.niri-desktop  # Niri + Noctalia (Gruvbox)
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
| `kitty.nix` | `kitty` | Kitty terminal with Gruvbox colors, cursor trail |
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
└── butternut/
    └── syncthing.yaml       (syncthing key/cert for butternut)
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
6. general creates the user, imports hjem
7. desktop sets up fonts, hardware, browsers (WM-agnostic)
8. sway sets WM config via home.programs.sway.settings
9. hjem/sway.nix converts settings → ~/.config/sway/config
10. Wrapped packages (terminal, fish, git, neovim, ...) are
    referenced by general.nix as the user's shell
```

## Invariants

- **One username, one place.** `modules/user.nix` defines `flake.user`. NixOS
  modules get it via `config.preferences.user.name`. Wrapped programs get it via
  `self.user`. Never hardcode a username.

- **Themes live in one place.** `modules/theme.nix` defines `flake.theme`
  (Gruvbox, used by niri/hyprland hosts) and `flake.catppuccin` (Catppuccin
  Latte, used by sway hosts). Modules reference `self.theme` or
  `self.catppuccin`. Never hardcode hex values.

- **Feature modules are independent.** A feature module should not import another
  feature module (except `desktop` which aggregates shared desktop basics). Hosts
  compose features.

- **desktop.nix is WM-agnostic.** It provides fonts, hardware, polkit, browsers.
  Window managers (sway, hyprland, niri) are separate modules chosen per-host.

- **Wrapped programs don't access NixOS config.** They're `perSystem` packages.
  They read `self.user` and `self.theme` from flake-level attrs, not from
  `config.preferences.*`.

- **hjem, not home-manager.** User-level file generation uses
  [hjem](https://github.com/feel-co/hjem), not home-manager. Config files are
  written via `hjem.users.<name>.files`.

- **Features own their infrastructure.** When a feature needs syncthing
  folders or sops secrets, it declares them itself (like `shared-zotero.nix`
  does). Host configs should not contain syncthing folder definitions or
  sops secret declarations that belong to a feature.

- **Secrets follow `secrets/<hostname>/`** convention. Feature modules
  resolve the right file via `config.networking.hostName`. Never hardcode
  a hostname in a sopsFile path.

- **Files must be git-tracked.** Nix flakes only see git-tracked files. New
  modules must be `git add`'ed before they're visible to `nix build`/`nix eval`.
