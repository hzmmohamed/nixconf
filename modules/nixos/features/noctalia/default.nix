# Noctalia v5 (native C++ shell) — the "noctalia" desktop shell for Sway hosts.
#
# All files in this directory contribute to `flake.nixosModules.noctalia`
# (one file per subsystem: bar, notification, theme, shell, plugin). Every
# file gates itself on preferences.desktopShell == "noctalia", so hosts can
# import this module unconditionally next to waybar/swaync.
#
# Not to be confused with modules/wrappedPrograms/noctalia (the old v4
# Quickshell wrapper used by maple's niri setup).
{inputs, ...}: {
  flake.nixosModules.noctalia = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    enabled = config.preferences.desktopShell == "noctalia";
    noctalia = config.home-manager.users.${user}.programs.noctalia.package;
    msg = "${lib.getExe noctalia} msg";

    # Same `dnd` CLI as the waybar/swaync stack, backed by Noctalia IPC.
    dnd = pkgs.writeShellScriptBin "dnd" ''
      case "''${1:-toggle}" in
        on) exec ${msg} notification-dnd-set on >/dev/null ;;
        off) exec ${msg} notification-dnd-set off >/dev/null ;;
        toggle) exec ${msg} notification-dnd-toggle >/dev/null ;;
        status) exec ${msg} notification-dnd-status ;;
        *) echo "usage: dnd on|off|toggle|status" >&2; exit 1 ;;
      esac
    '';
    dndToggle = pkgs.writeShellScriptBin "dnd-toggle" ''exec ${dnd}/bin/dnd toggle'';

    screenshareDndOn = pkgs.writeShellScript "screenshare-dnd-on" ''
      state="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/dnd-before-screenshare"
      [ -e "$state" ] || ${dnd}/bin/dnd status >"$state"
      ${dnd}/bin/dnd on
    '';
    screenshareDndOff = pkgs.writeShellScript "screenshare-dnd-off" ''
      state="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/dnd-before-screenshare"
      [ -e "$state" ] || exit 0
      prev=$(cat "$state"); rm -f "$state"
      [ "$prev" = off ] && ${dnd}/bin/dnd off
      exit 0
    '';

    # Bring Noctalia's light/dark mode in line with the theme state (on start).
    syncThemeMode = pkgs.writeShellScript "noctalia-sync-theme" ''
      mode=$(${lib.getExe config.preferences.theme.package} get 2>/dev/null) || exit 0
      case "$mode" in dark|light) exec ${msg} theme-mode-set "$mode" ;; esac
    '';
  in {
    config = lib.mkMerge [
      # Imported unconditionally (both modes); the HM module is inert until
      # programs.noctalia.enable is set below.
      {home-manager.users.${user}.imports = [inputs.noctalia.homeModules.default];}

      (lib.mkIf enabled {
        xdg.portal.wlr.settings.screencast = {
          exec_before = "${screenshareDndOn}";
          exec_after = "${screenshareDndOff}";
        };

        preferences.theme.reloadHooks.noctalia = ''
          ${msg} theme-mode-set "$mode" >/dev/null 2>&1 || true
        '';

        home-manager.users.${user} = {
          programs.noctalia = {
            enable = true;
            systemd.enable = true;
            checkConfig = true;
          };

          home.packages = [pkgs.libnotify dnd dndToggle];

          # MPRIS: track the most recently active player for playerctl/media keys.
          services.playerctld.enable = true;

          # The HM unit is PartOf/After/WantedBy graphical-session.target (which
          # sway-session.target pulls in once sway has exported its environment).
          # Same safety net as waybar: retry instead of giving up early.
          systemd.user.services.noctalia = {
            Unit = {
              After = ["sway-session.target"];
              StartLimitIntervalSec = 60;
              StartLimitBurst = 30;
            };
            Service = {
              RestartSec = 1;
              ExecStartPost = ["-${syncThemeMode}"];
            };
          };

          # Quiet hours (same schedule as the swaync stack).
          systemd.user.services.dnd-on = {
            Unit.Description = "Enable Do Not Disturb";
            Service = {
              Type = "oneshot";
              ExecStart = "${dnd}/bin/dnd on";
            };
          };
          systemd.user.timers.dnd-on = {
            Unit.Description = "Enable DND at 22:00";
            Timer = {
              OnCalendar = "*-*-* 22:00:00";
              Persistent = true;
            };
            Install.WantedBy = ["timers.target"];
          };
          systemd.user.services.dnd-off = {
            Unit.Description = "Disable Do Not Disturb";
            Service = {
              Type = "oneshot";
              ExecStart = "${dnd}/bin/dnd off";
            };
          };
          systemd.user.timers.dnd-off = {
            Unit.Description = "Disable DND at 08:00";
            Timer = {
              OnCalendar = "*-*-* 08:00:00";
              Persistent = true;
            };
            Install.WantedBy = ["timers.target"];
          };

          # Launcher stays vicinae (Mod4+space); these mirror the waybar stack.
          wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault {
            "Mod4+Shift+b" = "exec ${msg} bar-toggle";
            "Mod4+Shift+n" = "exec ${msg} panel-toggle control-center notifications";
          };
        };
      })
    ];
  };
}
