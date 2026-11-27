{
  flake.nixosModules.powersave = {
    pkgs,
    lib,
    ...
  }: {
    services.power-profiles-daemon.enable = true;
    services.thermald.enable = true;
    powerManagement.powertop.enable = true;

    # Except the wired NIC: `powertop --auto-tune` turns on PCI runtime PM
    # for every device, so an ethernet controller without link
    # runtime-suspends and relies on a PME wake-up when a cable appears. With
    # Realtek r8169 (hazel's RTL8111) that wake-up is unreliable: the port
    # stays NO-CARRIER after plugging in. Ethernet controllers (PCI class
    # 0x0200xx) stay powered: the udev rule covers hotplug/boot order, the
    # postStart loop runs because powertop starts after udev and overrides
    # it. Costs well under 1 W while unplugged. (butternut already opts out
    # of powertop entirely, hosts/butternut/gpu.nix.)
    services.udev.extraRules = ''
      ACTION=="add|bind", SUBSYSTEM=="pci", ATTR{class}=="0x0200*", TEST=="power/control", ATTR{power/control}="on"
    '';
    powerManagement.powertop.postStart = ''
      for dev in /sys/bus/pci/devices/*; do
        case "$(cat "$dev/class" 2>/dev/null)" in
          0x0200*) echo on > "$dev/power/control" 2>/dev/null || true ;;
        esac
      done
    '';

    hardware.amdgpu.overdrive.enable = true;
    services.lact.enable = true;

    systemd.services.lact-monitor = {
      enable = true;
      description = "Monitor PowerProfiles and update LACT profile";
      # lactd and ppd order themselves after multi-user.target: order after it
      # directly, or its implicit After= on what it wants closes a cycle and
      # systemd drops this unit at boot.
      after = ["multi-user.target" "network.target" "lactd.service" "power-profiles-daemon.service"];
      wants = ["lactd.service" "power-profiles-daemon.service"];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = lib.getExe (pkgs.writeShellApplication {
          name = "lact-initial-set";
          runtimeInputs = [pkgs.lact pkgs.glib pkgs.dbus pkgs.power-profiles-daemon];
          text = ''
            profile=$(powerprofilesctl get)
            if [[ $profile == "power-saver" ]]; then
                lact cli profile set "power-saver"
            else
                lact cli profile set "default"
            fi
          '';
        });
        ExecStart = lib.getExe (pkgs.writeShellApplication {
          name = "lact-watcher";
          runtimeInputs = [pkgs.libnotify pkgs.lact pkgs.glib pkgs.dbus pkgs.gnugrep];
          text = ''
            gdbus monitor --system --dest net.hadess.PowerProfiles |
            while read -r line; do
                if [[ $line =~ ActiveProfile ]]; then
                    profile=$(echo "$line" | grep -oP "(?<=<').+?(?='>)")

                    if [[ $profile == "power-saver" ]]; then
                        lact cli profile set "power-saver"
                    else
                        lact cli profile set "default"
                    fi
                fi
            done
          '';
        });
        Restart = "always";
        User = "root";
      };
      wantedBy = ["multi-user.target"];
    };
  };
}
