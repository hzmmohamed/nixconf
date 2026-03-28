# Sway WM Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Migrate the Sway window manager configuration from the old Snowfall Lib config into the new flake-parts repo, aligned with the repo's module design philosophy.

**Architecture:** Follow the Hyprland pattern: a `flake.nixosModules.sway` feature module sets NixOS options and defines Sway config via `home.programs.sway.settings`, and a paired hjem integration module generates `~/.config/sway/config`. Sway "addons" (waybar, swaylock, swayidle, etc.) become independent feature modules under `modules/nixos/features/` — not nested under sway — so they can be composed freely per-host. The `preferences.*` system (keymap, monitors, autostart) is consumed where applicable.

**Tech Stack:** NixOS modules, flake-parts, hjem, sway, waybar, swayidle, swaylock, wofi, wl-clipboard, cliphist, gammastep

---

## Design Decisions

### Why this structure?

The current repo has a flat feature module design:
- `modules/nixos/features/hyprland.nix` — one file, one `flake.nixosModules.hyprland`
- `modules/nixos/features/desktop.nix` — WM-agnostic desktop base
- `modules/nixos/extra/hjem/hyprland.nix` — hjem bridge for Hyprland config generation

Sway follows the same pattern:
- **`modules/nixos/features/sway.nix`** — `flake.nixosModules.sway` (the WM itself + keybindings + settings)
- **`modules/nixos/extra/hjem/sway.nix`** — hjem bridge generating `~/.config/sway/config`
- **`modules/nixos/features/waybar.nix`** — `flake.nixosModules.waybar` (independent, works with any WM)
- **`modules/nixos/features/swayidle.nix`** — `flake.nixosModules.swayidle` (screen lock + idle)
- **`modules/nixos/features/cliphist.nix`** — `flake.nixosModules.cliphist` (clipboard history)
- **`modules/nixos/features/gammastep.nix`** — `flake.nixosModules.gammastep` (blue light filter)

### What we DON'T migrate:
- **Wofi** — Noctalia's app launcher covers this; wofi only used for swayr/cliphist piping
- **Mako** — Noctalia handles notifications; swaync also not needed
- **Wlogout** — Noctalia has session controls
- **GTK theming** — already exists as `self.nixosModules.gtk` with Gruvbox
- **Alacritty/Foot** — current config uses Kitty terminal (already wrapped)
- **Darkman** — no light/dark switching in current config (Gruvbox only)
- **Kanshi** — monitor config via `preferences.monitors` instead
- **rbw** — separate migration item (not Sway-specific)
- **Flameshot** — was a placeholder in old config anyway

### Sway config generation

The old config used Home Manager's `wayland.windowManager.sway.config.*` structured options. The new config doesn't use Home Manager — it uses **hjem** for file generation. So we need a `home.programs.sway` options namespace (like `home.programs.hyprland`) and a generator that converts Nix attrs → Sway config syntax, then writes via hjem.

Sway config is simpler than Hyprland: it's just `key value` pairs and `section { ... }` blocks. We can write a simple `toSwayConfig` generator.

---

## Task 1: Sway hjem bridge — options + config generator

**Files:**
- Create: `modules/nixos/extra/hjem/sway.nix`

This module:
1. Defines `home.programs.sway.{enable, settings, extraConfig, finalConfig}` options
2. Generates `~/.config/sway/config` via hjem when enabled
3. Integrates `preferences.autostart` as `exec` commands
4. Integrates `preferences.monitors` as `output` directives

**Step 1: Create the hjem sway bridge module**

```nix
# modules/nixos/extra/hjem/sway.nix
{
  self,
  lib,
  ...
}: let
  # Sway config generator: converts Nix attrs to sway config syntax
  # key = "value"       → key value
  # section = { ... }   → section { ... }
  # list values         → repeated keys
  toSwayConfig = {
    attrs,
    indentLevel ? 0,
  }: let
    indent = lib.concatStrings (lib.replicate indentLevel "    ");
    nextIndent = indentLevel + 1;

    renderValue = name: value:
      if lib.isAttrs value then
        ''
          ${indent}${name} {
          ${toSwayConfig { attrs = value; indentLevel = nextIndent; }}${indent}}
        ''
      else if lib.isList value then
        lib.concatMapStringsSep "" (v: renderValue name v) value
      else
        "${indent}${name} ${toString value}\n";
  in
    lib.concatStrings (lib.mapAttrsToList renderValue attrs);
in {
  flake.nixosModules.extra_hjem_sway = {
    lib,
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    cfg = config.home.programs.sway;
  in {
    options.home.programs.sway = {
      enable = lib.mkEnableOption "sway configuration";

      settings = lib.mkOption {
        default = {};
        description = "Sway configuration as Nix attribute set";
      };

      extraConfig = lib.mkOption {
        default = "";
        type = lib.types.lines;
        description = "Extra sway configuration appended verbatim";
      };

      finalConfig = lib.mkOption {
        default = "";
        readOnly = true;
      };
    };

    config = lib.mkIf cfg.enable {
      home.programs.sway.finalConfig =
        (toSwayConfig { attrs = cfg.settings; })
        + cfg.extraConfig;

      hjem.users.${user} = {
        files.".config/sway/config".text = cfg.finalConfig;
      };

      # Map preferences.autostart to exec lines
      home.programs.sway.extraConfig = lib.mkBefore (
        lib.concatMapStringsSep "\n" (entry:
          let
            exe =
              if (builtins.typeOf entry) == "string"
              then lib.getExe (pkgs.writeShellScriptBin "autostart" entry)
              else lib.getExe entry;
          in "exec ${exe}"
        ) config.preferences.autostart
      );
    };
  };
}
```

**Step 2: Verify module evaluates**

Run: `git add modules/nixos/extra/hjem/sway.nix && nix eval .#nixosModules.extra_hjem_sway --no-write-lock-file`
Expected: no error (outputs `<LAMBDA>`)

**Step 3: Commit**

```
feat: add sway hjem bridge for config generation
```

---

## Task 2: Sway feature module

**Files:**
- Create: `modules/nixos/features/sway.nix`

This is the main Sway WM module — equivalent to `modules/nixos/features/hyprland.nix`. It enables Sway, defines all settings, keybindings, input config, and system packages.

**Step 1: Create the sway feature module**

```nix
# modules/nixos/features/sway.nix
{self, ...}: {
  flake.nixosModules.sway = {
    config,
    lib,
    pkgs,
    ...
  }: let
    mod = "Mod4";
    terminal = lib.getExe self.packages.${pkgs.system}.terminal;
  in {
    imports = [
      self.nixosModules.extra_hjem_sway
    ];

    programs.sway = {
      enable = true;
      wrapperFeatures.gtk = true;
    };

    home.programs.sway.enable = true;

    home.programs.sway.settings = {
      # Modifier
      set = {
        "$mod" = mod;
      };

      # Input
      "input type:keyboard" = {
        xkb_layout = "us,ara";
        xkb_options = "grp:shift_super_toggle,caps:escape";
      };

      "input type:touchpad" = {
        dwt = "enabled";
        tap = "enabled";
        natural_scroll = "disabled";
        middle_emulation = "enabled";
      };

      # Appearance
      gaps = {
        inner = "8";
      };
      default_border = "pixel 4";
      default_floating_border = "pixel 1";

      # Focus
      focus_follows_mouse = "yes";

      # Monitor config from preferences
      # (handled in extraConfig since it needs dynamic attr access)

      # Keybindings
      "bindsym ${mod}+Return" = "exec ${terminal}";
      "bindsym ${mod}+Shift+c" = "kill";
      "bindsym ${mod}+space" = "exec wofi --show drun";
      "bindsym ${mod}+f" = "fullscreen toggle";
      "bindsym ${mod}+Shift+f" = "floating toggle";
      "bindsym ${mod}+a" = "focus parent";
      "bindsym ${mod}+Shift+d" = "reload";

      # Layout
      "bindsym ${mod}+i" = "layout stacking";
      "bindsym ${mod}+w" = "layout tabbed";
      "bindsym ${mod}+e" = "layout toggle split";

      # Navigation
      "bindsym ${mod}+Left" = "focus left";
      "bindsym ${mod}+Down" = "focus down";
      "bindsym ${mod}+Up" = "focus up";
      "bindsym ${mod}+Right" = "focus right";
      "bindsym ${mod}+h" = "focus left";
      "bindsym ${mod}+j" = "focus down";
      "bindsym ${mod}+k" = "focus up";
      "bindsym ${mod}+l" = "focus right";

      # Move windows
      "bindsym ${mod}+Shift+Left" = "move left";
      "bindsym ${mod}+Shift+Down" = "move down";
      "bindsym ${mod}+Shift+Up" = "move up";
      "bindsym ${mod}+Shift+Right" = "move right";
      "bindsym ${mod}+Shift+h" = "move left";
      "bindsym ${mod}+Shift+j" = "move down";
      "bindsym ${mod}+Shift+k" = "move up";
      "bindsym ${mod}+Shift+l" = "move right";

      # Scratchpad
      "bindsym ${mod}+Shift+minus" = "move scratchpad";
      "bindsym ${mod}+minus" = "scratchpad show";

      # Audio
      "bindsym --locked XF86AudioRaiseVolume" = "exec wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+";
      "bindsym --locked XF86AudioLowerVolume" = "exec wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%-";
      "bindsym --locked XF86AudioMute" = "exec wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
      "bindsym --locked XF86AudioMicMute" = "exec wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle";

      # Media
      "bindsym --locked XF86AudioPlay" = "exec playerctl play-pause";
      "bindsym --locked XF86AudioNext" = "exec playerctl next";
      "bindsym --locked XF86AudioPrev" = "exec playerctl previous";

      # Brightness
      "bindsym XF86MonBrightnessUp" = "exec light -A 5";
      "bindsym XF86MonBrightnessDown" = "exec light -U 5";
      "bindsym Shift+XF86MonBrightnessUp" = "exec light -A 1";
      "bindsym Shift+XF86MonBrightnessDown" = "exec light -U 1";

      # Resize mode
      "mode \"resize\"" = {
        "bindsym Left" = "resize shrink width 10px";
        "bindsym Down" = "resize grow height 10px";
        "bindsym Up" = "resize shrink height 10px";
        "bindsym Right" = "resize grow width 10px";
        "bindsym Return" = "mode default";
        "bindsym Escape" = "mode default";
      };
      "bindsym ${mod}+r" = "mode \"resize\"";
    };

    # Workspace bindings + monitor output via extraConfig
    # (structured attrs can't express workspace 1-9 loops cleanly)
    home.programs.sway.extraConfig = let
      workspaceBindings = lib.concatMapStringsSep "\n" (n:
        let ws = toString n; in ''
          bindsym ${mod}+${ws} workspace number ${ws}
          bindsym ${mod}+Shift+${ws} move container to workspace number ${ws}
        ''
      ) [1 2 3 4 5 6 7 8 9];

      monitorConfig = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: m:
          if m.enabled then
            "output ${name} resolution ${toString m.width}x${toString m.height}@${toString m.refreshRate}Hz position ${toString m.x} ${toString m.y}"
          else
            "output ${name} disable"
        ) config.preferences.monitors
      );
    in ''
      ${workspaceBindings}
      ${monitorConfig}
    '';

    environment.systemPackages = with pkgs; [
      wl-clipboard
      grim
      slurp
      wofi
      playerctl
      light
    ];

    # Brightness control needs video group
    users.users.${config.preferences.user.name}.extraGroups = ["video"];

    # Wayland env vars
    environment.sessionVariables = {
      QT_QPA_PLATFORM = "wayland";
      QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
      MOZ_ENABLE_WAYLAND = "1";
      XDG_SESSION_TYPE = "wayland";
      XDG_CURRENT_DESKTOP = "sway";
      NIXOS_OZONE_WL = "1";
    };
  };
}
```

**Step 2: Verify module evaluates**

Run: `git add modules/nixos/features/sway.nix && nix flake show --no-write-lock-file 2>&1 | grep sway`
Expected: `nixosModules.sway` and `nixosModules.extra_hjem_sway` both appear

**Step 3: Commit**

```
feat: add sway window manager feature module
```

---

## Task 3: Swayidle + Swaylock feature module

**Files:**
- Create: `modules/nixos/features/swayidle.nix`

Independent module for screen lock and idle management. Works with Sway (or any Wayland WM).

**Step 1: Create the swayidle module**

```nix
# modules/nixos/features/swayidle.nix
{self, ...}: {
  flake.nixosModules.swayidle = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    swaylockCmd = "${lib.getExe pkgs.swaylock} -f -c 282828";
  in {
    environment.systemPackages = with pkgs; [
      swaylock
      swayidle
    ];

    # Allow swaylock to authenticate
    security.pam.services.swaylock = {};

    # swayidle config via hjem
    hjem.users.${user}.files.".config/swayidle/config".text = ''
      timeout 300 '${swaylockCmd}'
      timeout 600 'swaymsg "output * power off"' resume 'swaymsg "output * power on"'
      before-sleep '${swaylockCmd}'
      lock '${swaylockCmd}'
    '';

    # Autostart swayidle
    preferences.autostart = [
      (pkgs.writeShellScriptBin "start-swayidle" ''
        exec ${lib.getExe pkgs.swayidle} -w
      '')
    ];
  };
}
```

**Step 2: Verify**

Run: `git add modules/nixos/features/swayidle.nix && nix flake show --no-write-lock-file 2>&1 | grep swayidle`
Expected: `nixosModules.swayidle` appears

**Step 3: Commit**

```
feat: add swayidle/swaylock screen lock module
```

---

## Task 4: Cliphist feature module

**Files:**
- Create: `modules/nixos/features/cliphist.nix`

Clipboard history manager — WM-agnostic, works with any Wayland compositor.

**Step 1: Create the cliphist module**

```nix
# modules/nixos/features/cliphist.nix
{...}: {
  flake.nixosModules.cliphist = {
    pkgs,
    ...
  }: {
    environment.systemPackages = with pkgs; [
      cliphist
      wl-clipboard
    ];

    # Autostart clipboard listener
    preferences.autostart = [
      (pkgs.writeShellScriptBin "start-cliphist" ''
        exec wl-paste --watch cliphist store
      '')
    ];

    # Keybinding to paste from clipboard history is defined in WM modules
    # For sway: bindsym Mod4+v exec cliphist list | wofi -S dmenu | cliphist decode | wl-copy
  };
}
```

**Step 2: Verify**

Run: `git add modules/nixos/features/cliphist.nix && nix flake show --no-write-lock-file 2>&1 | grep cliphist`
Expected: `nixosModules.cliphist` appears

**Step 3: Commit**

```
feat: add cliphist clipboard history module
```

---

## Task 5: Gammastep feature module

**Files:**
- Create: `modules/nixos/features/gammastep.nix`

Blue light filter — WM-agnostic.

**Step 1: Create the gammastep module**

```nix
# modules/nixos/features/gammastep.nix
{...}: {
  flake.nixosModules.gammastep = {
    pkgs,
    ...
  }: {
    environment.systemPackages = [pkgs.gammastep];

    preferences.autostart = [
      (pkgs.writeShellScriptBin "start-gammastep" ''
        exec ${pkgs.lib.getExe pkgs.gammastep} -l 30.0:31.2 -t 6500:3500
      '')
    ];
  };
}
```

Note: coordinates 30.0:31.2 are for Cairo, Egypt — adjust to user's location.

**Step 2: Verify**

Run: `git add modules/nixos/features/gammastep.nix && nix flake show --no-write-lock-file 2>&1 | grep gammastep`
Expected: `nixosModules.gammastep` appears

**Step 3: Commit**

```
feat: add gammastep blue light filter module
```

---

## Task 6: Waybar feature module

**Files:**
- Create: `modules/nixos/features/waybar.nix`

Status bar — independent module, works with Sway and other Wayland WMs.

**Step 1: Create the waybar module**

```nix
# modules/nixos/features/waybar.nix
{self, ...}: {
  flake.nixosModules.waybar = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    theme = self.theme;
  in {
    environment.systemPackages = [pkgs.waybar];

    preferences.autostart = [
      (pkgs.writeShellScriptBin "start-waybar" ''
        exec ${lib.getExe pkgs.waybar}
      '')
    ];

    # Waybar config via hjem
    hjem.users.${user}.files.".config/waybar/config.jsonc".text = builtins.toJSON {
      layer = "top";
      position = "top";
      reload_style_on_change = true;

      modules-left = ["sway/workspaces" "sway/mode"];
      modules-center = ["clock"];
      modules-right = ["cpu" "memory" "battery" "tray"];

      "sway/workspaces" = {
        format = "{icon}";
        format-icons = {
          active = "";
          default = "○";
        };
      };

      "sway/mode" = {
        format = "{}";
      };

      clock = {
        format = "{:%H:%M}";
        format-alt = "{:%A, %B %d, %Y}";
        tooltip-format = "<tt>{calendar}</tt>";
      };

      cpu = {
        format = " {usage}%";
        interval = 5;
      };

      memory = {
        format = " {percentage}%";
        interval = 5;
      };

      battery = {
        states = {
          good = 95;
          warning = 30;
          critical = 20;
        };
        format = "{icon} {capacity}%";
        format-icons = ["" "" "" "" ""];
        format-charging = " {capacity}%";
      };

      tray = {
        spacing = 10;
      };
    };

    hjem.users.${user}.files.".config/waybar/style.css".text = ''
      * {
        font-family: "JetBrainsMono Nerd Font", monospace;
        font-size: 13px;
      }

      window#waybar {
        background: ${theme.base00};
        color: ${theme.base05};
      }

      #workspaces button {
        padding: 0 5px;
        color: ${theme.base04};
      }

      #workspaces button.focused {
        color: ${theme.base0E};
      }

      #clock, #cpu, #memory, #battery, #tray {
        padding: 0 10px;
      }

      #battery.warning {
        color: ${theme.base09};
      }

      #battery.critical {
        color: ${theme.base08};
      }
    '';
  };
}
```

**Step 2: Verify**

Run: `git add modules/nixos/features/waybar.nix && nix flake show --no-write-lock-file 2>&1 | grep waybar`
Expected: `nixosModules.waybar` appears

**Step 3: Commit**

```
feat: add waybar status bar module
```

---

## Task 7: Wire sway modules into butternut host

**Files:**
- Modify: `modules/nixos/hosts/butternut/configuration.nix`
- Modify: `modules/vm.nix`

**Step 1: Add sway modules to butternut host**

In `modules/nixos/hosts/butternut/configuration.nix`, add to the imports list of `hostButternut`:

```nix
self.nixosModules.sway
self.nixosModules.swayidle
self.nixosModules.cliphist
self.nixosModules.gammastep
self.nixosModules.waybar
```

Also add the cliphist keybinding to the sway extraConfig by adding to the module:

```nix
home.programs.sway.extraConfig = lib.mkAfter ''
  bindsym Mod4+v exec cliphist list | wofi -S dmenu | cliphist decode | wl-copy
'';
```

**Step 2: Add sway modules to VM config**

In `modules/vm.nix`, add the same sway module imports so the VM tests the full Sway desktop.

**Step 3: Verify both evaluate**

Run:
```bash
nix eval .#nixosConfigurations.butternut.config.networking.hostName --no-write-lock-file
nix eval .#nixosConfigurations.butternut-vm.config.system.build.toplevel.drvPath --no-write-lock-file
```
Expected: `"butternut"` and a valid derivation path

**Step 4: Commit**

```
feat: wire sway desktop into butternut host and VM
```

---

## Task 8: Update TODO.md

**Files:**
- Modify: `TODO.md`

Mark completed items and note any follow-ups discovered during implementation.

**Step 1: Update TODO.md**

Check off:
- Sway WM migration
- Screen lock / idle (swayidle)
- Clipboard history (cliphist)
- Blue light filter (gammastep)

**Step 2: Commit**

```
docs: update migration TODO after sway migration
```
