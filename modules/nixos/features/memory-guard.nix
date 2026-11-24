# Memory guard: keep the desktop usable under memory pressure.
#
# Without swap, a machine short on memory evicts the only pages it can, the
# code of running programs, sway's included: every frame then faults, the
# cursor freezes and the kernel OOM killer only fires minutes later. So:
#
#   swap        zram first (compressed RAM), then an optional swapfile on
#               disk, so anonymous memory has somewhere to go before code
#               pages are thrown out.
#   reserve     MemoryMin on logind session scopes (and their parents, since
#               cgroup protection only reaches as far as every ancestor
#               grants it): sway, Xwayland and whatever sway exec'd itself are
#               never reclaimed below `reserve`. Apps run in their own
#               app-*.scope under user@.service and are not covered.
#   early kill  systemd-oomd kills the biggest swap user once swap is nearly
#               full (session scopes omitted). Agent slices opt into
#               pressure kills in agent-host / agent-t3code. Builds are capped
#               in nix-daemon's own cgroup, where the kernel kills a compiler
#               rather than the daemon (OOMPolicy=continue).
#   rescue      (desktop) Ctrl+Shift+Escape (Mod+Escape locks) toggles an
#               htop started by sway at login, so it lives in the protected
#               session scope and is already resident when it is needed. `q`
#               restarts it, closing the window ends it; the key starts a
#               new one.
#   last resort Alt+SysRq+F makes the kernel OOM-kill the biggest process;
#               Alt+SysRq+R,E,I,S,U,B reboots cleanly.
#
# Check:  systemctl show "session-$XDG_SESSION_ID.scope" -p MemoryMin
#         oomctl;  swapon --show;  cat /proc/pressure/memory
{self, ...}: {
  flake.nixosModules.memory-guard = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.memoryGuard;
    user = config.preferences.user.name;
    font = "${self.fonts.monospace}:size=${toString self.fonts.size}";

    # htop sorted by memory: works at any window size (btop refuses below a
    # minimum), header still shows memory/swap, F9 or k kills. Its own
    # htoprc lives in the runtime dir, so ~/.config/htop is left alone.
    rescueRun = pkgs.writeShellApplication {
      name = "rescue-top-run";
      runtimeInputs = [pkgs.htop pkgs.coreutils];
      text = ''
        export HTOPRC="''${XDG_RUNTIME_DIR:-/tmp}/rescue-htoprc"
        while true; do
          htop --sort-key=PERCENT_MEM || sleep 1
        done
      '';
    };
    # The window rule's resize does not survive the first scratchpad show
    # (it comes up at foot's default 70x22), so size it on every show; when
    # the toggle hid it instead, the workspace criterion matches nothing.
    rescueTop = pkgs.writeShellApplication {
      name = "rescue-top";
      runtimeInputs = [pkgs.sway pkgs.foot];
      text = ''
        crit='[app_id="^rescue-top$"]'
        if [ "''${1:-}" != --start ] && swaymsg "$crit scratchpad show" >/dev/null 2>&1; then
          swaymsg "''${crit%]} workspace=__focused__] resize set width 80 ppt height 80 ppt, move position center" >/dev/null 2>&1 || true
          exit 0
        fi
        exec foot --app-id rescue-top --override 'font=${font}' ${lib.getExe rescueRun}
      '';
    };
  in {
    options.preferences.memoryGuard = {
      reserve = lib.mkOption {
        type = lib.types.str;
        default = "1G";
        description = "MemoryMin of each login session scope (sway and what it exec'd itself).";
      };
      swapfileSize = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        example = 16 * 1024;
        description = "Size in MiB of /var/lib/swapfile, behind zram. null: zram only.";
      };
      buildMemoryMax = lib.mkOption {
        type = lib.types.str;
        default = "75%";
        description = "MemoryMax of nix-daemon.service (all local builds together); MemoryHigh throttles 10 points below.";
      };
    };

    config = lib.mkMerge [
      {
        zramSwap = {
          enable = true;
          memoryPercent = 50;
        };
        swapDevices = lib.optional (cfg.swapfileSize != null) {
          device = "/var/lib/swapfile";
          size = cfg.swapfileSize;
          # Below zram (priority 5).
          priority = 0;
        };
        boot.kernel.sysctl = {
          # zram is cheaper to swap to than dropping code pages.
          "vm.swappiness" = 100;
          # No read-ahead on swap-in (zram has no seek cost).
          "vm.page-cluster" = 0;
          # sync (16), remount ro (32), signal/OOM-kill (64), reboot (128).
          "kernel.sysrq" = 240;
        };

        systemd.oomd.enable = true;
        systemd.slices."-".sliceConfig.ManagedOOMSwap = "kill";

        systemd.slices.user.sliceConfig.MemoryMin = cfg.reserve;
        systemd.units."user-.slice" = {
          text = ''
            [Slice]
            MemoryMin=${cfg.reserve}
          '';
          overrideStrategy = "asDropin";
        };
        systemd.units."session-.scope" = {
          text = ''
            [Scope]
            MemoryMin=${cfg.reserve}
            ManagedOOMPreference=omit
          '';
          overrideStrategy = "asDropin";
        };

        systemd.services.nix-daemon.serviceConfig = let
          pct = lib.toInt (lib.removeSuffix "%" cfg.buildMemoryMax);
        in {
          MemoryHigh = lib.mkDefault (
            if lib.hasSuffix "%" cfg.buildMemoryMax
            then "${toString (pct - 10)}%"
            else "infinity"
          );
          MemoryMax = cfg.buildMemoryMax;
          # A build OOM-killed inside the cgroup fails; the daemon stays up.
          OOMPolicy = "continue";
        };
      }

      (lib.mkIf config.preferences.desktop.enable {
        home-manager.users.${user}.wayland.windowManager.sway.config = {
          # Started by sway itself, so it lands in the protected session scope.
          startup = [{command = "${lib.getExe rescueTop} --start";}];
          window.commands = [
            {
              criteria.app_id = "^rescue-top$";
              command = "floating enable, move scratchpad";
            }
          ];
          keybindings = lib.mkOptionDefault {
            "Ctrl+Shift+Escape" = "exec ${lib.getExe rescueTop}";
          };
        };
      })
    ];
  };
}
