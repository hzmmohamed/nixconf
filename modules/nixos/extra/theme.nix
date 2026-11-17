# Unified light/dark switching (implements the preferences.theme.* options
# declared in base/theme.nix). Imported by `general`, next to the
# home-manager bridge.
#
# Runtime layout (per user):
#   ~/.local/state/theme/light   -> store dir with every registered file (light)
#   ~/.local/state/theme/dark    -> same, dark
#   ~/.local/state/theme/current -> "light" | "dark" (relative symlink)
#
# `theme-mode light|dark` flips `current`, writes the registered dconf keys and
# runs every reload hook. darkman calls it; nothing else switches modes.
#
# Phase 5 (wallpaper source) can write real directories in place of the
# light/dark store links; `current` and the hooks stay the same.
{...}: {
  flake.nixosModules.extra_theme = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.theme;
    user = config.preferences.user.name;
    state = cfg.stateDir;
    enabled = cfg.files != {} || cfg.dconf != {} || cfg.reloadHooks != {};

    renderDir = mode:
      pkgs.linkFarm "theme-${mode}" (lib.mapAttrsToList (name: render: {
          inherit name;
          path = pkgs.writeText "theme-${mode}-${name}" (render cfg.palette.${mode});
        })
        cfg.files);

    dconfWrites = mode:
      lib.concatStringsSep "\n" (lib.mapAttrsToList (key: v: ''
        ${pkgs.dconf}/bin/dconf write ${lib.escapeShellArg key} ${lib.escapeShellArg v.${mode}} || true'')
      cfg.dconf);

    dconfBlock = ''
      case "$mode" in
        light)
          ${dconfWrites "light"}
          ;;
        dark)
          ${dconfWrites "dark"}
          ;;
      esac
    '';

    hookScripts = lib.mapAttrs (name: text:
      pkgs.writeShellScript "theme-hook-${name}" ''
        mode="$1"
        ${text}
      '')
    cfg.reloadHooks;

    themeMode = pkgs.writeShellScriptBin "theme-mode" ''
      set -u
      state=${lib.escapeShellArg state}
      current() { ${pkgs.coreutils}/bin/readlink "$state/current" 2>/dev/null || echo light; }

      case "''${1:-}" in
        get) current; exit 0 ;;
        light|dark) mode="$1" ;;
        apply) mode="$(current)" ;;
        *) echo "usage: theme-mode light|dark|apply|get" >&2; exit 2 ;;
      esac

      if [ ! -e "$state/$mode" ]; then
        echo "theme-mode: $state/$mode is missing (has home-manager activation run?)" >&2
        exit 1
      fi

      ${pkgs.coreutils}/bin/ln -sfn "$mode" "$state/.current.new"
      ${pkgs.coreutils}/bin/mv -Tf "$state/.current.new" "$state/current"

      ${dconfBlock}

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: script: ''
        ${script} "$mode" || echo "theme-mode: reload hook '${name}' failed" >&2'')
      hookScripts)}
      exit 0
    '';
  in {
    config = lib.mkMerge [
      {preferences.theme.package = themeMode;}

      (lib.mkIf enabled {
        home-manager.users.${user} = hm: {
          home.packages = [themeMode];

          # Link the per-mode dirs and app links before (re)starting user
          # services, so e.g. waybar never sees a missing @import.
          home.activation.themeState = hm.lib.hm.dag.entryBetween ["reloadSystemd"] ["writeBoundary"] ''
            state=${lib.escapeShellArg state}
            run mkdir -p "$state"
            run ln -sfn ${renderDir "light"} "$state/light"
            run ln -sfn ${renderDir "dark"} "$state/dark"

            if [ ! -L "$state/current" ]; then
              mode=light
              ${lib.optionalString hm.config.services.darkman.enable ''
              bus="/run/user/$(${pkgs.coreutils}/bin/id -u)/bus"
              if [ -S "$bus" ]; then
                m="$(DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" ${pkgs.darkman}/bin/darkman get 2>/dev/null || true)"
                case "$m" in light|dark) mode="$m" ;; esac
              fi
            ''}
              run ln -sfn "$mode" "$state/current"
            fi

            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (path: file: ''
                target="$HOME/"${lib.escapeShellArg path}
                run mkdir -p "$(dirname "$target")"
                if [ -e "$target" ] && [ ! -L "$target" ]; then
                  run mv "$target" "$target.backup"
                fi
                run ln -sfn "$state/current/"${lib.escapeShellArg file} "$target"
              '')
              cfg.links)}
          '';

          # home-manager's gtk module rewrites org/gnome/desktop/interface on
          # every activation; re-apply the *current* mode afterwards so a
          # rebuild at night stays dark.
          home.activation.themeDconf = hm.lib.hm.dag.entryAfter ["dconfSettings" "themeState"] ''
            bus="/run/user/$(${pkgs.coreutils}/bin/id -u)/bus"
            if [ -S "$bus" ]; then (
              export DBUS_SESSION_BUS_ADDRESS="unix:path=$bus"
              mode="$(${pkgs.coreutils}/bin/readlink ${lib.escapeShellArg state}/current 2>/dev/null || echo light)"
              if [ -z "''${DRY_RUN:-}" ]; then
                ${dconfBlock}
              fi
            )
            fi
          '';
        };
      })
    ];
  };
}
