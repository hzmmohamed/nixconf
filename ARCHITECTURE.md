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
| `theme.nix` | `flake.theme`, `flake.themeNoHash` | Gruvbox color palette used by terminal, bar, WM, etc. |
| `flake-parts.nix` | systems, options | Declares mergeable flake options (`wrapperModules`, `diskoConfigurations`). |
| `devshell.nix` | `perSystem.devShells.default` | `nix develop` shell with nix tooling. |
| `vm.nix` | `nixosConfigurations.butternut-vm` | QEMU VM for testing. Auto-logs into Sway via greetd. |

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
| `desktop` | WM-agnostic desktop base: fonts, polkit, bluetooth, graphics, pipewire, browsers | `gtk`, `wallpaper`, `pipewire`, `firefox`, `chromium` |
| `sway` | Sway WM: keybinds, input (US+Arabic), gaps, brightness, session vars | `extra_hjem_sway` |
| `hyprland` | Hyprland WM: keybinds, animations, monitors, dwindle layout | (uses `home.programs.hyprland` consumed by hjem) |
| `waybar` | Status bar: workspaces, clock, CPU/mem/battery, Gruvbox CSS | |
| `swayidle` | Screen lock (swaylock) + idle timeout + DPMS | |
| `cliphist` | Clipboard history daemon (wl-paste + cliphist) | |
| `gammastep` | Blue light filter | |
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
| `wallpaper` | swww daemon with wallpaper image | |

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
| **butternut** | Sway | Intel i915, LUKS ext4 | ASUS laptop, SSH server, asusd, WayVNC |

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
| `niri.nix` | `niri` | Niri compositor with keybinds, which-key menus |
| `noctalia/` | `noctalia-shell` | Desktop shell: bar, launcher, notifications, OSD, screen recorder |
| `git.nix` | `git` | Git with author name/email from `self.user` |
| `jj.nix` | `jujutsu`, `jjui` | Jujutsu VCS + TUI with user config |
| `nh.nix` | `nh` | Nix helper with flake path |
| `lf.nix` | `lf` | File manager with shortcuts and preview |
| `qalc.nix` | `qalc` | Calculator |
| `wlr-which-key/` | (library) | Which-key menu generator, used by niri |
| `quickshell/` | `quickshellWrapped` | Quickshell with zoxide |

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

- **One theme, one place.** `modules/theme.nix` defines `flake.theme`. All
  colors reference it. Never hardcode hex values.

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

- **Files must be git-tracked.** Nix flakes only see git-tracked files. New
  modules must be `git add`'ed before they're visible to `nix build`/`nix eval`.
