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
#
# phone-profile: butternut's phone profile (dictation-server, phone.profile)
# has exactly the shape the app parses (data classes of apps/phone/…/
# profile/Profile.kt, walked by dictation/phone-profile-check.py) and the
# values it relies on (version, servers, four hashed Parakeet files).
#
# attn-wiring: hazel and butternut run attn instead of ActivityWatch (the
# attn feature): daemon + sensor, a dir:// sink, agent-net for the metered
# policy, swayidle's extra idle/resume entry, awatcher, the fish cwd hook,
# SWAYSOCK in the user manager, distinct device ids, no ActivityWatch units.
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
    # butternut serves the phone profile (dictation-server, phone.enable).
    phoneProfile = self.nixosConfigurations.butternut.config.preferences.dictation-server.phone.profile;

    attnHosts = ["hazel" "butternut"];
    attnAsserts = h: let
      c = self.nixosConfigurations.${h}.config;
      hm = c.home-manager.users.${c.preferences.user.name};
      dev = c.services.attn.device;
      sensor = c.services.attn.sensor;
      noCtx = builtins.unsafeDiscardStringContext;
      checks = {
        "daemon and sensor enabled" = dev.enable && sensor.enable;
        "sink is the local dir" = dev.sink == "dir:///var/lib/attn/sink";
        "at least one recipient" = dev.recipients != [];
        "agent-net on the daemon's PATH" = lib.any (p: (p.pname or p.name) == "agent-net") c.systemd.services.attn-daemon.path;
        "daemon may open AF_NETLINK" = lib.hasInfix "AF_NETLINK" (noCtx c.systemd.units."attn-daemon.service".text);
        "swayidle keeps lock + screen-off and adds attn" = builtins.length hm.services.swayidle.timeouts == 3;
        "swayidle tells the sensor about idle" =
          lib.any (t: t.timeout == 180 && t.command == sensor.idleCommands.idle && t.resumeCommand == sensor.idleCommands.active)
          hm.services.swayidle.timeouts;
        "awatcher user service" = hm.systemd.user.services ? awatcher;
        # A swayidle restart drops a pending resume: clear the flag on start.
        "swayidle start clears the sensor's idle flag" =
          lib.elem "-${sensor.idleCommands.active}" (lib.toList (hm.systemd.user.services.swayidle.Service.ExecStartPre or []));
        # First deploy: aw-server may still hold 5600 for a moment.
        "daemon restarts slowly enough to outlast a port clash" = (c.systemd.services.attn-daemon.serviceConfig.RestartSec or null) == 5;
        "no ActivityWatch units" =
          !hm.services.activitywatch.enable
          && !(lib.any (lib.hasPrefix "activitywatch") (lib.attrNames hm.systemd.user.services));
        "Clockify extension gone" = !(lib.any (e: e.id == "pmjeegjhjdlccodhacdgbgfagbpmccpe") hm.programs.chromium.extensions);
        "SWAYSOCK imported into the user manager" =
          hm.wayland.windowManager.sway.systemd.enable && lib.elem "SWAYSOCK" hm.wayland.windowManager.sway.systemd.variables;
        "fish cwd hook" = lib.hasInfix "attn-sensor.sock" (noCtx c.programs.fish.interactiveShellInit);
      };
    in
      lib.mapAttrsToList (name: ok: lib.assertMsg ok "attn-wiring: ${h}: ${name}") checks;
    attnDeviceIds = map (h: self.nixosConfigurations.${h}.config.services.attn.device.deviceId) attnHosts;
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

        phone-profile =
          pkgs.runCommand "phone-profile-check" {
            nativeBuildInputs = [pkgs.python3];
          } ''
            python3 ${./nixos/features/dictation/phone-profile-check.py} \
              ${../apps/phone/app/src/main/java/nixconf/phone/profile/Profile.kt} \
              ${phoneProfile}
            cp ${phoneProfile} $out
          '';

        attn-wiring = assert lib.all lib.id (lib.concatMap attnAsserts attnHosts);
        assert lib.assertMsg (lib.unique attnDeviceIds == attnDeviceIds) "attn-wiring: device ids must differ between hosts";
          pkgs.runCommand "attn-wiring" {} "touch $out";
      };
  };
}
