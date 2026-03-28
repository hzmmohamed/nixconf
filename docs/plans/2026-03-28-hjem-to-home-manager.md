# Hjem → Home Manager Migration

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace all hjem usage with Home Manager, using native HM modules wherever possible.

**Architecture:** Add home-manager as a flake input, create a base HM NixOS module (replacing hjem.nix), then migrate each module that uses `hjem.users.${user}.files.*` to either a native HM module (fish, atuin, yazi, waybar, sway, hyprland) or `home-manager.users.${user}.home.file.*` for raw file drops (vscode, vr). Finally, move the wrapped fish config into HM's `programs.fish` and delete hjem infrastructure.

**Tech Stack:** NixOS, Home Manager, flake-parts, import-tree

---

## Current hjem touchpoints

| File | hjem usage | HM replacement |
|------|-----------|----------------|
| `flake.nix` | `hjem` input | `home-manager` input |
| `modules/nixos/extra/hjem/hjem.nix` | Base hjem setup | HM NixOS module |
| `modules/nixos/extra/hjem/sway.nix` | Custom `home.programs.sway` options → file | HM `wayland.windowManager.sway` |
| `modules/nixos/extra/hjem/hyprland.nix` | Custom `home.programs.hyprland` options → file + `toHyprconf` generator | HM `wayland.windowManager.hyprland` |
| `modules/nixos/features/sway.nix` | Uses `home.programs.sway.*` | `home-manager.users.${user}.wayland.windowManager.sway` |
| `modules/nixos/features/hyprland.nix` | Uses `home.programs.hyprland.*` | `home-manager.users.${user}.wayland.windowManager.hyprland` |
| `modules/nixos/features/waybar.nix` | `hjem.users.${user}.files` for config + CSS | `home-manager.users.${user}.programs.waybar` |
| `modules/nixos/features/yazi.nix` | `hjem.users.${user}.files` for toml | `home-manager.users.${user}.programs.yazi` |
| `modules/nixos/features/atuin.nix` | `hjem.users.${user}.files` for toml | `home-manager.users.${user}.programs.atuin` |
| `modules/nixos/features/vscode.nix` | `hjem.users.${user}.files` for JSON | `home-manager.users.${user}.home.file` |
| `modules/nixos/features/vr.nix` | `hjem.users.${user}.files` for JSON | `home-manager.users.${user}.home.file` |
| `modules/nixos/features/general.nix` | Imports `extra_hjem` | Import HM base module |
| `modules/nixos/hosts/butternut/configuration.nix` | `home.programs.sway.extraConfig` | `home-manager.users.${user}.wayland.windowManager.sway.extraConfig` |
| `modules/wrappedPrograms/fish.nix` | N/A (wrapped config) | Move to HM `programs.fish` |

---

### Task 1: Add Home Manager input, replace hjem

**Files:**
- Modify: `flake.nix`

**Step 1: Edit flake.nix**

Replace the `hjem` input with `home-manager`:

```nix
# Remove:
hjem = {
  url = "github:feel-co/hjem";
  inputs.nixpkgs.follows = "nixpkgs";
};

# Add:
home-manager = {
  url = "github:nix-community/home-manager";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

**Step 2: Verify syntax**

Run: `nix flake show --no-build 2>&1 | head -5`
Expected: May fail (hjem still referenced elsewhere), that's OK — we'll fix consumers next.

---

### Task 2: Replace hjem base module with Home Manager base

**Files:**
- Rewrite: `modules/nixos/extra/hjem/hjem.nix`

**Step 1: Rewrite hjem.nix as HM base**

Replace the entire file with:

```nix
{inputs, ...}: {
  flake.nixosModules.extra_hjem = {config, ...}: let
    user = config.preferences.user.name;
  in {
    imports = [
      inputs.home-manager.nixosModules.home-manager
    ];

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      backupFileExtension = "backup";

      users.${user} = {
        home = {
          username = user;
          homeDirectory = "/home/${user}";
          stateVersion = config.system.stateVersion;
        };
      };
    };
  };
}
```

Note: We keep the module name `extra_hjem` to avoid touching every importer in this step. It can be renamed later.

---

### Task 3: Migrate atuin.nix to HM programs.atuin

**Files:**
- Modify: `modules/nixos/features/atuin.nix`

**Step 1: Rewrite atuin.nix**

```nix
{...}: {
  flake.nixosModules.atuin = {
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
  in {
    environment.systemPackages = [pkgs.atuin];

    home-manager.users.${user}.programs.atuin = {
      enable = true;
      settings = {
        auto_sync = true;
        sync_frequency = "5m";
        sync_address = "https://api.atuin.sh";
        inline_height = 15;
        enter_accept = false;
        keymap_mode = "vim-insert";
        keymap_cursor = {
          emacs = "blink-block";
          vim_insert = "blink-bar";
          vim_normal = "steady-block";
        };
      };
    };
  };
}
```

**Step 2: Verify build**

Run: `nix build .#nixosConfigurations.butternut.config.system.build.toplevel --dry-run 2>&1 | tail -5`

---

### Task 4: Migrate yazi.nix to HM programs.yazi

**Files:**
- Modify: `modules/nixos/features/yazi.nix`

**Step 1: Rewrite yazi.nix**

```nix
{...}: {
  flake.nixosModules.yazi = {
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
  in {
    environment.systemPackages = with pkgs; [
      yazi
      imagemagick
      poppler-utils
    ];

    home-manager.users.${user}.programs.yazi = {
      enable = true;
      settings.log.enabled = false;
      settings.manager = {
        show_hidden = false;
        show_symlink = true;
        linemode = "mtime";
        sort_by = "modified";
        sort_dir_first = true;
        sort_reverse = true;
      };
    };
  };
}
```

---

### Task 5: Migrate vscode.nix to HM home.file

**Files:**
- Modify: `modules/nixos/features/vscode.nix`

**Step 1: Replace hjem file drop with HM home.file**

Change:
```nix
hjem.users.${user}.files.".config/VSCodium/User/settings.json".text = settings;
```
To:
```nix
home-manager.users.${user}.home.file.".config/VSCodium/User/settings.json".text = settings;
```

The rest of the file stays the same.

---

### Task 6: Migrate vr.nix to HM home.file

**Files:**
- Modify: `modules/nixos/features/vr.nix`

**Step 1: Replace hjem with HM home.file**

Change:
```nix
hjem.users.${user} = {
  files.".config/openxr/1/active_runtime.json".source = ...;
  files.".config/openvr/openvrpaths.vrpath".text = ...;
};
```
To:
```nix
home-manager.users.${user}.home.file = {
  ".config/openxr/1/active_runtime.json".source = "${pkgs.wivrn}/share/openxr/1/openxr_wivrn.json";
  ".config/openvr/openvrpaths.vrpath".text = ...;
};
```

---

### Task 7: Migrate waybar.nix to HM home.file

**Files:**
- Modify: `modules/nixos/features/waybar.nix`

**Step 1: Replace hjem file drops with HM home.file**

Change:
```nix
hjem.users.${user}.files = {
  ".config/waybar/config".text = waybarConfig;
  ".config/waybar/style.css".text = waybarStyle;
};
```
To:
```nix
home-manager.users.${user}.home.file = {
  ".config/waybar/config".text = waybarConfig;
  ".config/waybar/style.css".text = waybarStyle;
};
```

---

### Task 8: Migrate sway config to HM wayland.windowManager.sway

This is the most complex task. The current system defines custom `home.programs.sway` NixOS options (in `extra/hjem/sway.nix`) that compile Nix attrs into sway config text. HM has its own structured sway module.

**Files:**
- Delete: `modules/nixos/extra/hjem/sway.nix`
- Rewrite: `modules/nixos/features/sway.nix`
- Modify: `modules/nixos/hosts/butternut/configuration.nix`

**Step 1: Rewrite sway.nix using HM sway module**

The current settings map to HM as follows:
- `home.programs.sway.settings."input type:keyboard"` → `config.input."type:keyboard"`
- `home.programs.sway.settings.gaps.inner` → `config.gaps.inner`
- `home.programs.sway.settings.default_border` → `config.window.border`
- `home.programs.sway.settings."bindsym ..."` → `config.keybindings`
- `home.programs.sway.extraConfig` (workspaces + monitors) → `extraConfig`
- `home.programs.sway.settings."exec_always"` → `config.startup`

```nix
{self, ...}: {
  flake.nixosModules.sway = {
    config,
    lib,
    pkgs,
    ...
  }: let
    mod = "Mod4";
    user = config.preferences.user.name;
    terminal = lib.getExe self.packages.${pkgs.system}.terminal;
  in {
    programs.sway = {
      enable = true;
      wrapperFeatures.gtk = true;
    };

    # Ensure the wayland-sessions .desktop file is linked into
    # /run/current-system/sw/share/wayland-sessions so greetd/tuigreet can find it.
    environment.pathsToLink = ["/share/wayland-sessions"];

    home-manager.users.${user}.wayland.windowManager.sway = {
      enable = true;

      config = {
        modifier = mod;
        terminal = terminal;
        menu = "wofi --show drun";

        input = {
          "type:keyboard" = {
            xkb_layout = "us,ara";
            xkb_options = "grp:shift_super_toggle,caps:escape";
          };
          "type:touchpad" = {
            dwt = "enabled";
            tap = "enabled";
            natural_scroll = "disabled";
            middle_emulation = "enabled";
          };
        };

        gaps.inner = 8;
        window = {
          border = 4;
          titlebar = false;
        };
        floating.border = 1;
        focus.followMouse = "yes";

        keybindings = lib.mkOptionDefault {
          # Navigation
          "${mod}+Left" = "focus left";
          "${mod}+Down" = "focus down";
          "${mod}+Up" = "focus up";
          "${mod}+Right" = "focus right";
          "${mod}+h" = "focus left";
          "${mod}+j" = "focus down";
          "${mod}+k" = "focus up";
          "${mod}+l" = "focus right";

          # Move windows
          "${mod}+Shift+Left" = "move left";
          "${mod}+Shift+Down" = "move down";
          "${mod}+Shift+Up" = "move up";
          "${mod}+Shift+Right" = "move right";
          "${mod}+Shift+h" = "move left";
          "${mod}+Shift+j" = "move down";
          "${mod}+Shift+k" = "move up";
          "${mod}+Shift+l" = "move right";

          # Core actions
          "${mod}+Return" = "exec ${terminal}";
          "${mod}+Shift+c" = "kill";
          "${mod}+space" = "exec wofi --show drun";
          "${mod}+f" = "fullscreen toggle";
          "${mod}+Shift+f" = "floating toggle";
          "${mod}+a" = "focus parent";
          "${mod}+Shift+d" = "reload";

          # Layout
          "${mod}+i" = "layout stacking";
          "${mod}+w" = "layout tabbed";
          "${mod}+e" = "layout toggle split";

          # Scratchpad
          "${mod}+Shift+minus" = "move scratchpad";
          "${mod}+minus" = "scratchpad show";

          # Audio
          "--locked XF86AudioRaiseVolume" = "exec wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+";
          "--locked XF86AudioLowerVolume" = "exec wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%-";
          "--locked XF86AudioMute" = "exec wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
          "--locked XF86AudioMicMute" = "exec wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle";

          # Media
          "--locked XF86AudioPlay" = "exec playerctl play-pause";
          "--locked XF86AudioNext" = "exec playerctl next";
          "--locked XF86AudioPrev" = "exec playerctl previous";

          # Brightness
          "XF86MonBrightnessUp" = "exec brightnessctl set 5%+";
          "XF86MonBrightnessDown" = "exec brightnessctl set 5%-";
          "Shift+XF86MonBrightnessUp" = "exec brightnessctl set 1%+";
          "Shift+XF86MonBrightnessDown" = "exec brightnessctl set 1%-";

          # Resize mode
          "${mod}+r" = "mode resize";

          # Workspaces
          "${mod}+1" = "workspace number 1";
          "${mod}+2" = "workspace number 2";
          "${mod}+3" = "workspace number 3";
          "${mod}+4" = "workspace number 4";
          "${mod}+5" = "workspace number 5";
          "${mod}+6" = "workspace number 6";
          "${mod}+7" = "workspace number 7";
          "${mod}+8" = "workspace number 8";
          "${mod}+9" = "workspace number 9";
          "${mod}+Shift+1" = "move container to workspace number 1";
          "${mod}+Shift+2" = "move container to workspace number 2";
          "${mod}+Shift+3" = "move container to workspace number 3";
          "${mod}+Shift+4" = "move container to workspace number 4";
          "${mod}+Shift+5" = "move container to workspace number 5";
          "${mod}+Shift+6" = "move container to workspace number 6";
          "${mod}+Shift+7" = "move container to workspace number 7";
          "${mod}+Shift+8" = "move container to workspace number 8";
          "${mod}+Shift+9" = "move container to workspace number 9";
        };

        modes.resize = {
          "Left" = "resize shrink width 10px";
          "Down" = "resize grow height 10px";
          "Up" = "resize shrink height 10px";
          "Right" = "resize grow width 10px";
          "Return" = "mode default";
          "Escape" = "mode default";
        };

        startup = [
          {command = "systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP && dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP"; always = true;}
        ];

        output = lib.mapAttrs (
          name: m:
            if m.enabled
            then {resolution = "${toString m.width}x${toString m.height}@${toString m.refreshRate}Hz"; position = "${toString m.x} ${toString m.y}";}
            else {disable = "";}
        ) config.preferences.monitors;
      };
    };

    environment.systemPackages = with pkgs; [
      wl-clipboard
      grim
      slurp
      wofi
      playerctl
      brightnessctl
    ];

    users.users.${user}.extraGroups = ["video"];

    xdg.portal = {
      enable = true;
      wlr.enable = true;
      extraPortals = [pkgs.xdg-desktop-portal-gtk];
      config.sway = {
        default = lib.mkForce ["wlr" "gtk"];
      };
    };

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

**Step 2: Update butternut/configuration.nix**

Change:
```nix
home.programs.sway.extraConfig = lib.mkAfter ''
  bindsym Mod4+v exec cliphist list | wofi -S dmenu | cliphist decode | wl-copy
'';
```
To:
```nix
home-manager.users.${config.preferences.user.name}.wayland.windowManager.sway.config.keybindings = {
  "Mod4+v" = "exec cliphist list | wofi -S dmenu | cliphist decode | wl-copy";
};
```

Note: `config.preferences.user.name` needs to be in scope — the module already has `lib` in its args but needs the user. Add `config` to the module args if not already there (it's available via `...`).

**Step 3: Delete the old hjem sway module**

Delete: `modules/nixos/extra/hjem/sway.nix`

**Step 4: Remove the import from sway.nix**

The old `sway.nix` had `imports = [ self.nixosModules.extra_hjem_sway ];` — this is no longer needed since we're not using that custom option system.

---

### Task 9: Migrate hyprland config to HM wayland.windowManager.hyprland

**Files:**
- Modify: `modules/nixos/features/hyprland.nix`
- Delete: `modules/nixos/extra/hjem/hyprland.nix`

**Step 1: Rewrite hyprland.nix using HM hyprland module**

The current `home.programs.hyprland.settings` attrs map directly to HM's `wayland.windowManager.hyprland.settings` — the structure is nearly identical since the hjem hyprland module was modeled after HM's.

```nix
{self, ...}: {
  flake.nixosModules.hyprland = {
    config,
    lib,
    pkgs,
    ...
  }: let
    mod = "SUPER";
    user = config.preferences.user.name;
    terminal = self.packages.${pkgs.system}.terminal;
  in {
    programs.hyprland.enable = true;

    home-manager.users.${user}.wayland.windowManager.hyprland = {
      enable = true;
      settings = {
        # Copy ALL the current settings from hyprland.nix verbatim —
        # HM's hyprland module uses the same toHyprconf format.
        # The entire `home.programs.hyprland.settings` block moves here as-is.

        workspace = [
          "w[t1], gapsout:0, gapsin:0"
          "w[tg1], gapsout:0, gapsin:0"
          "f[1], gapsout:0, gapsin:0"
        ];

        windowrulev2 = [
          "bordersize 0, floating:0, onworkspace:w[t1]"
          "rounding 0, floating:0, onworkspace:w[t1]"
          "bordersize 0, floating:0, onworkspace:w[tg1]"
          "rounding 0, floating:0, onworkspace:w[tg1]"
          "bordersize 0, floating:0, onworkspace:f[1]"
          "rounding 0, floating:0, onworkspace:f[1]"
        ];

        general = {
          gaps_in = 5;
          gaps_out = 10;
          border_size = 2;
          "col.active_border" = lib.mkForce "rgba(${self.themeNoHash.base0E}ff) rgba(${self.themeNoHash.base09}ff) 60deg";
          "col.inactive_border" = lib.mkForce "rgba(${self.themeNoHash.base00}ff)";
          layout = "dwindle";
        };

        monitor = lib.mapAttrsToList (
          name: m: let
            resolution = "${toString m.width}x${toString m.height}@${toString m.refreshRate}";
            position = "${toString m.x}x${toString m.y}";
          in "${name},${
            if m.enabled
            then "${resolution},${position},1"
            else "disable"
          }"
        ) config.preferences.monitors;

        env = ["XCURSOR_SIZE,24"];

        input = {
          kb_layout = "us,ru,ua";
          kb_variant = "";
          kb_model = "";
          kb_options = "grp:alt_shift_toggle,caps:escape";
          kb_rules = "";
          follow_mouse = 1;
          touchpad.natural_scroll = false;
          repeat_rate = 40;
          repeat_delay = 250;
          force_no_accel = true;
          sensitivity = 0.0;
        };

        misc = {
          enable_swallow = true;
          force_default_wallpaper = 0;
        };

        binds.movefocus_cycles_fullscreen = 0;
        debug.suppress_errors = true;

        decoration = {
          rounding = 12;
          rounding_power = 7;
          shadow = {
            enabled = true;
            shadow_range = 30;
          };
        };

        animations = {
          enabled = true;
          bezier = "myBezier, 0.25, 0.9, 0.1, 1.02";
          animation = [
            "windows, 1, 7, myBezier"
            "windowsOut, 1, 7, default, popin 80%"
            "border, 1, 10, default"
            "borderangle, 1, 8, default"
            "fade, 1, 7, default"
            "workspaces, 1, 3, myBezier, fade"
          ];
        };

        dwindle = {
          pseudotile = true;
          preserve_split = true;
          force_split = 2;
        };

        master = {};

        gestures.workspace_swipe = false;

        exec-once = builtins.map (entry:
          if (builtins.typeOf entry) == "string"
          then lib.getExe (pkgs.writeShellScriptBin "autostart" entry)
          else lib.getExe entry
        ) config.preferences.autostart;

        bind = let
          toWSNumber = n: toString (if n == 0 then 10 else n);
          moveworkspaces = map (n: "${mod} SHIFT, ${toString n}, movetoworkspace, ${toWSNumber n}") [1 2 3 4 5 6 7 8 9 0];
          woworkspaces = map (n: "${mod}, ${toString n}, workspace, ${toWSNumber n}") [1 2 3 4 5 6 7 8 9 0];
        in [
          "${mod}, return, exec, ${lib.getExe terminal}"
          "${mod}, Q, killactive,"
          "${mod} SHIFT, F, togglefloating,"
          "${mod}, F, fullscreen,"
          "${mod}, T, pin,"
          "${mod}, G, togglegroup,"
          "${mod}, bracketleft, changegroupactive, b"
          "${mod}, bracketright, changegroupactive, f"
          "${mod}, S, exec, ${lib.getExe self.packages.${pkgs.system}.noctalia-shell} ipc call launcher toggle"
          "${mod}, P, pin, active"
          ",XF86AudioRaiseVolume, exec, wpctl set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 5%+"
          ",XF86AudioLowerVolume, exec, wpctl set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 5%-"
          "${mod}, left, movefocus, l"
          "${mod}, right, movefocus, r"
          "${mod}, up, movefocus, u"
          "${mod}, down, movefocus, d"
          "${mod}, h, movefocus, l"
          "${mod}, l, movefocus, r"
          "${mod}, k, movefocus, u"
          "${mod}, j, movefocus, d"
          "${mod} SHIFT, h, movewindow, l"
          "${mod} SHIFT, l, movewindow, r"
          "${mod} SHIFT, k, movewindow, u"
          "${mod} SHIFT, j, movewindow, d"
        ] ++ woworkspaces ++ moveworkspaces;

        binde = [
          "${mod} SHIFT, h, moveactive, -20 0"
          "${mod} SHIFT, l, moveactive, 20 0"
          "${mod} SHIFT, k, moveactive, 0 -20"
          "${mod} SHIFT, j, moveactive, 0 20"
          "${mod} CTRL, l, resizeactive, 30 0"
          "${mod} CTRL, h, resizeactive, -30 0"
          "${mod} CTRL, k, resizeactive, 0 -10"
          "${mod} CTRL, j, resizeactive, 0 10"
        ];

        bindm = [
          "${mod}, mouse:272, movewindow"
          "${mod}, mouse:273, resizewindow"
        ];
      };
    };

    environment.systemPackages = with pkgs; [
      grim slurp wl-clipboard swww networkmanagerapplet rofi
    ];
  };
}
```

**Step 2: Delete hyprland hjem module**

Delete: `modules/nixos/extra/hjem/hyprland.nix`

**Important:** The `hyprland.nix` hjem module also defines `flake.nixosModules.extra_hjem` with the `home.programs.hyprland` options and a `preferences.keymap` → hyprland submap generator. The keymap → submap logic currently lives there. If this feature is still in use (check `preferences.keymap` references), the submap generation needs to move into the hyprland feature module. If unused, just drop it.

---

### Task 10: Create fish HM module and clean up wrapped fish

**Files:**
- Create: `modules/nixos/features/fish.nix`
- Modify: `modules/wrappedPrograms/fish.nix` (remove config, keep as package)
- Modify: `modules/nixos/features/general.nix` (import fish module)

**Step 1: Create fish.nix**

```nix
{self, ...}: {
  flake.nixosModules.fish = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    selfpkgs = self.packages.${pkgs.system};
  in {
    programs.fish.enable = true;

    home-manager.users.${user}.programs.fish = {
      enable = true;
      shellAliases = {
        rm = "rm -i";
        cp = "cp -i";
        mv = "mv -i";
        mkdir = "mkdir -p";
      };
      shellAbbrs = {
        g = "git";
        o = "open";
        lg = "lazygit";
        kc = "kubectl";
        kx = "kubectx";
        cl = "clear";
        yz = "yazi";
        zj = "zellij";
        jtl = "journalctl";
        stl = "systemctl";
      };
      interactiveShellInit = ''
        set fish_greeting

        fish_vi_key_bindings

        if type -q direnv
          direnv hook fish | source
        end
      '';
    };
  };
}
```

**Step 2: Simplify wrapped fish**

`modules/wrappedPrograms/fish.nix` — remove the inline config since HM manages it. Keep only the wrapper for `runtimeInputs` (starship, zoxide are needed on PATH):

```nix
{
  inputs,
  lib,
  ...
}: {
  perSystem = {
    pkgs,
    self',
    ...
  }: let
    lf = self'.packages.lf;
  in {
    packages.fish = inputs.wrappers.lib.wrapPackage {
      inherit pkgs;
      package = pkgs.fish;
      runtimeInputs = [
        pkgs.zoxide
        pkgs.starship
      ];
    };
  };
}
```

Note: starship init and zoxide init were in the old fish config. With HM, use HM's `programs.starship` and `programs.zoxide` instead. Add to fish.nix:

```nix
home-manager.users.${user}.programs.starship.enable = true;
home-manager.users.${user}.programs.zoxide.enable = true;
```

Then starship and zoxide runtimeInputs can be removed from the wrapper too.

**Step 3: Import fish module**

In `modules/nixos/features/general.nix`, add to imports:
```nix
self.nixosModules.fish
```

Or add it per-host in the host configuration files (butternut, maple, etc.) alongside other modules.

---

### Task 11: Update general.nix — remove programs.fish.enable

**Files:**
- Modify: `modules/nixos/features/general.nix`

**Step 1: Remove the programs.fish.enable line**

The fish module from Task 10 now handles `programs.fish.enable = true`. Remove it from general.nix (it was added earlier in this conversation).

---

### Task 12: Delete hjem extra modules and clean up

**Files:**
- Delete: `modules/nixos/extra/hjem/sway.nix` (if not done in Task 8)
- Delete: `modules/nixos/extra/hjem/hyprland.nix` (if not done in Task 9)
- Verify: `modules/nixos/extra/hjem/hjem.nix` is now the HM base module (done in Task 2)

**Step 1: Verify no remaining hjem references**

Run: `grep -r "hjem" modules/ --include="*.nix" | grep -v "extra_hjem"`
Expected: No results (all `hjem.users` references are gone).

**Step 2: Remove hjem input from flake.lock**

Run: `nix flake update home-manager`
This updates the lock file, adding home-manager and the old hjem entry will be garbage collected.

---

### Task 13: Full build verification

**Step 1: Build all hosts dry-run**

Run:
```bash
nix build .#nixosConfigurations.butternut.config.system.build.toplevel --dry-run
nix build .#nixosConfigurations.maple.config.system.build.toplevel --dry-run
nix build .#nixosConfigurations.main.config.system.build.toplevel --dry-run
nix build .#nixosConfigurations.mini.config.system.build.toplevel --dry-run
```

**Step 2: Build desktop VM to test sway config**

Run: `nix build .#nixosConfigurations.desktop-vm.config.system.build.toplevel --dry-run`

**Step 3: Commit**

```bash
git add -A
git commit -m "refactor: replace hjem with home-manager

Migrate all hjem file management to Home Manager:
- Use native HM modules for fish, atuin, yazi, sway, hyprland
- Use HM home.file for vscode, vr, waybar configs
- Add fish module with shellAliases, shellAbbrs, and plugins
- Remove hjem flake input and custom hjem modules"
```
