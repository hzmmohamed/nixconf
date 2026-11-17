# Eval-only checks: `nix build .#checks.x86_64-linux.<host>-eval` (or
# `nix flake check`) forces evaluation of every nixosConfiguration without
# building it. The drvPath string has its context discarded, so the check
# derivation does not depend on (and never builds) the system closure.
#
# design-contrast: the colour-role contract of docs/plans/2026-11-17-design-
# system.md (extra/theme-palette.py CONTRACT) holds for the static Catppuccin
# palettes and for wallpaper palettes generated (matugen + the same generator
# the hosts run) from both bundled default wallpapers, in light and dark; and
# no themed module hardcodes a hex colour (modules/theme.nix is the one place).
{
  lib,
  self,
  ...
}: {
  # All hosts are x86_64-linux (the only entry in `systems`).
  perSystem = {pkgs, ...}: let
    generator = ./nixos/extra/theme-palette.py;
    wallpapers = lib.importJSON ./nixos/features/wallpaper/meta.json;
    image = m:
      pkgs.fetchurl {
        inherit (m) url hash;
        name = m.file;
      };
    paletteJson = mode:
      pkgs.writeText "catppuccin-${mode}.json" (builtins.toJSON (
        lib.filterAttrs (k: v: builtins.isString v || k == "accentName")
        (builtins.removeAttrs self.palettes.catppuccin.${mode} ["noHash"])
      ));
    # Themed modules: every .nix file that may read the palette
    # (wrappedPrograms/noctalia/noctalia.nix is the dead v4 config).
    nixOnly = name:
      builtins.path {
        path = ./. + "/${name}";
        name = "themed-${name}";
        filter = path: type:
          type == "directory" || (lib.hasSuffix ".nix" path && baseNameOf path != "noctalia.nix");
      };
  in {
    checks =
      lib.mapAttrs' (name: nixos:
        lib.nameValuePair "${name}-eval" (
          pkgs.runCommand "${name}-eval" {} ''
            echo ${builtins.unsafeDiscardStringContext nixos.config.system.build.toplevel.drvPath} > $out
          ''
        ))
      self.nixosConfigurations
      // {
        design-contrast =
          pkgs.runCommand "design-contrast" {
            nativeBuildInputs = [pkgs.python3 pkgs.matugen pkgs.gnugrep];
          } ''
            set -u
            fail=0
            echo "== Catppuccin (modules/theme.nix)"
            python3 ${generator} --check ${paletteJson "light"} --check ${paletteJson "dark"} || fail=1

            mkdir -p empty
            for which in light dark; do
              case $which in
                light) img=${image wallpapers.light} ;;
                dark) img=${image wallpapers.dark} ;;
              esac
              for mode in light dark; do
                echo "== wallpaper ${"$"}{which} default, $mode mode"
                matugen image "$img" -m "$mode" --json hex --dry-run -q --source-color-index 0 </dev/null > m.json
                case $mode in
                  light) fb=${paletteJson "light"} ;;
                  dark) fb=${paletteJson "dark"} ;;
                esac
                python3 ${generator} --matugen m.json --mode "$mode" --fallback "$fb" \
                  --templates empty --out "out-$which-$mode" || fail=1
                python3 ${generator} --check "out-$which-$mode/palette.json" || fail=1
              done
            done

            echo "== hardcoded hex colours in themed modules"
            if grep -rnE '#[0-9a-fA-F]{6}\b' ${nixOnly "nixos"} ${nixOnly "wrappedPrograms"}; then
              echo "colours must come from the palette (modules/theme.nix)"; fail=1
            fi

            [ "$fail" = 0 ] || exit 1
            mkdir -p $out
            cp -r out-*/palette.json $out/ 2>/dev/null || true
            for d in out-*; do cp "$d/palette.json" "$out/$d.json"; done
            echo ok > $out/result
          '';
      };
  };
}
