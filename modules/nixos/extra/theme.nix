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
# runs every reload hook. darkman calls it (through preferences.theme.
# switchCommand, which the wallpaper feature points at `set-wallpaper --mode`).
#
# Wallpaper source (preferences.theme.source = "wallpaper"):
#   `theme-mode generate IMAGE` runs matugen once per (image sha256, mode),
#   cached in ~/.cache/theme/<sha>/matugen-<mode>.json, and renders the same
#   per-app files into ~/.cache/theme/<sha>/{light,dark}/ with theme-palette.py:
#   the Nix renderers (preferences.theme.files) are applied to a *placeholder*
#   palette ("@@THEME:<key>@@") at build time, and the generator fills in the
#   wallpaper palette (pinned -> wallpaper -> Catppuccin fallback, WCAG guard).
#   light/dark then point into the cache instead of the store; `current`, the
#   links and the hooks stay the same. Optional per-key overrides ("pinned
#   scheme"): ~/.config/theme/pinned.json = {"light": {...}, "dark": {...}}.
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
    wallpaperSource = cfg.source == "wallpaper";

    renderWith = prefix: palettes: mode:
      pkgs.linkFarm "${prefix}-${mode}" (lib.mapAttrsToList (name: render: {
          inherit name;
          path = pkgs.writeText "${prefix}-${mode}-${name}" (render palettes.${mode});
        })
        cfg.files);

    # Build-time (Catppuccin) palette files; also the runtime fallback.
    renderDir = renderWith "theme" cfg.palette;

    # Same renderers over a placeholder palette: the templates the wallpaper
    # generator fills in. Non-colour keys (isDark, accentName) stay real.
    colourKeys = p: builtins.filter (k: builtins.isString p.${k} && k != "accentName") (builtins.attrNames p);
    placeholder = mode: let
      p = cfg.palette.${mode};
      keys = colourKeys p;
    in
      p
      // lib.genAttrs keys (k: "@@THEME:${k}@@")
      // {noHash = lib.genAttrs keys (k: "@@THEME_NOHASH:${k}@@");};
    templateDir = renderWith "theme-template" (lib.genAttrs ["light" "dark"] placeholder);

    fallbackJson = mode:
      pkgs.writeText "theme-fallback-${mode}.json" (builtins.toJSON (
        lib.filterAttrs (k: v: builtins.isString v || k == "accentName") (builtins.removeAttrs cfg.palette.${mode} ["noHash"])
      ));

    generator = pkgs.writers.writePython3 "theme-palette" {
      flakeIgnore = ["E501" "E226" "W503"];
    } (builtins.readFile ./theme-palette.py);

    # Everything that changes the rendered output; re-render when it differs.
    renderStamp = mode: "${generator} ${templateDir mode} ${fallbackJson mode}";

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

    coreutils = "${pkgs.coreutils}/bin";

    themeMode = pkgs.writeShellScriptBin "theme-mode" ''
      set -u
      state=${lib.escapeShellArg state}
      ${pkgs.coreutils}/bin/mkdir -p "$state"
      current() { ${pkgs.coreutils}/bin/readlink "$state/current" 2>/dev/null || echo light; }

      # Point $state/<mode> at a directory (atomic symlink swap).
      link_mode() {
        ${coreutils}/ln -sfn "$2" "$state/.$1.new"
        ${coreutils}/mv -Tf "$state/.$1.new" "$state/$1"
      }

      fallback() {
        ${coreutils}/mkdir -p "$state"
        link_mode light ${renderDir "light"}
        link_mode dark ${renderDir "dark"}
      }

      ${lib.optionalString wallpaperSource ''
        # One mode: matugen (cached per image sha256 + mode), then render.
        generate_mode() {
          m="$1"; img="$2"; dir="$3"
          json="$dir/matugen-$m.json"
          if [ ! -s "$json" ]; then
            if ${lib.getExe pkgs.matugen} image "$img" -m "$m" --json hex \
                --dry-run -q --source-color-index 0 </dev/null >"$json.tmp"; then
              ${coreutils}/mv -f "$json.tmp" "$json"
            else
              ${coreutils}/rm -f "$json.tmp"
              echo "theme-mode: matugen failed for $img ($m); Catppuccin fallback" >&2
            fi
          fi

          pinned="''${XDG_CONFIG_HOME:-$HOME/.config}/theme/pinned.json"
          stamp="$m ${renderStamp "light"} ${renderStamp "dark"} $(${coreutils}/cat "$pinned" 2>/dev/null | ${coreutils}/sha256sum) $(${coreutils}/stat -c %Y "$json" 2>/dev/null)"
          out="$dir/$m"
          if [ "$(${coreutils}/cat "$out/.stamp" 2>/dev/null)" != "$stamp" ]; then
            ${coreutils}/rm -rf "$out.tmp"
            case "$m" in
              light) tpl=${templateDir "light"}; fb=${fallbackJson "light"} ;;
              *) tpl=${templateDir "dark"}; fb=${fallbackJson "dark"} ;;
            esac
            ${generator} --matugen "$json" --mode "$m" --fallback "$fb" \
              --pinned "$pinned" --templates "$tpl" --out "$out.tmp" || return 1
            printf '%s' "$stamp" >"$out.tmp/.stamp"
            if [ -e "$out" ]; then ${coreutils}/mv -T "$out" "$out.old"; fi
            ${coreutils}/mv -T "$out.tmp" "$out"
            ${coreutils}/rm -rf "$out.old"
          fi
          link_mode "$m" "$out"
        }

        generate() {
          img="$(${coreutils}/realpath -e "$1")" || { echo "theme-mode: no such image: $1" >&2; fallback; return 1; }
          sha="$(${coreutils}/sha256sum <"$img" | ${coreutils}/cut -c1-64)"
          cache="''${XDG_CACHE_HOME:-$HOME/.cache}/theme"
          ${coreutils}/mkdir -p "$cache/$sha" "$state"
          ${coreutils}/touch "$cache/$sha"
          rc=0
          for m in light dark; do
            generate_mode "$m" "$img" "$cache/$sha" || {
              echo "theme-mode: rendering $m failed; Catppuccin fallback" >&2
              case "$m" in
                light) link_mode light ${renderDir "light"} ;;
                *) link_mode dark ${renderDir "dark"} ;;
              esac
              rc=1
            }
          done
          printf '%s\n' "$img" >"$state/image"
          # Keep the 30 most recently used images' palettes.
          ${coreutils}/ls -1t "$cache" | ${coreutils}/tail -n +31 | while IFS= read -r old; do
            case "$old" in ""|.*) ;; *) ${coreutils}/rm -rf "''${cache:?}/$old" ;; esac
          done
          return "$rc"
        }
      ''}

      case "''${1:-}" in
        get) current; exit 0 ;;
        light|dark) mode="$1" ;;
        apply) mode="$(current)" ;;
        fallback) fallback; exit 0 ;;
        generate)
          [ -n "''${2:-}" ] || { echo "usage: theme-mode generate IMAGE" >&2; exit 2; }
          ${
        if wallpaperSource
        then ''
          exec 9>"$state/.lock"
          ${pkgs.util-linux}/bin/flock 9
          generate "$2"; exit $?''
        else ''
          exit 0 # Catppuccin source: nothing to generate''
      }
          ;;
        *) echo "usage: theme-mode light|dark|apply|get|generate IMAGE|fallback" >&2; exit 2 ;;
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
      {
        preferences.theme = {
          package = themeMode;
          switchCommand = lib.mkDefault (lib.getExe themeMode);
          rendered = {
            light = renderDir "light";
            dark = renderDir "dark";
            light-template = templateDir "light";
            dark-template = templateDir "dark";
          };
        };
      }

      (lib.mkIf enabled {
        home-manager.users.${user} = hm: {
          home.packages = [themeMode];

          # Link the per-mode dirs and app links before (re)starting user
          # services, so e.g. waybar never sees a missing @import.
          home.activation.themeState = hm.lib.hm.dag.entryBetween ["reloadSystemd"] ["writeBoundary"] ''
            state=${lib.escapeShellArg state}
            run mkdir -p "$state"
            ${
              if wallpaperSource
              then ''
                # Re-render the current wallpaper's palette (templates may
                # have changed); Catppuccin until a wallpaper was set.
                img="$(cat "$state/image" 2>/dev/null || true)"
                if [ -n "$img" ] && [ -e "$img" ]; then
                  run ${themeMode}/bin/theme-mode generate "$img" || run ${themeMode}/bin/theme-mode fallback
                else
                  run ${themeMode}/bin/theme-mode fallback
                fi
              ''
              else ''
                run ln -sfn ${renderDir "light"} "$state/light"
                run ln -sfn ${renderDir "dark"} "$state/dark"
              ''
            }

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
