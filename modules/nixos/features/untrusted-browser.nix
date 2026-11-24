{
  inputs,
  self,
  ...
}: let
  # Disposable Firefox VM for sites/downloads you don't trust.
  #
  #   browse-untrusted [url]     (or "Untrusted Browser" in the launcher)
  #
  # The guest (nixosConfigurations.untrusted-vm) boots straight into Firefox
  # (cage kiosk, uBlock Origin) in a plain QEMU window and powers off when
  # Firefox closes. Nothing survives a run except what lands in ~/Untrusted.
  #
  # Isolation, and why each default of qemu-vm.nix is replaced:
  # - Root is tmpfs (diskImage = null): every launch starts clean.
  # - Store: an erofs image of the guest's own closure, built by Nix. The
  #   default 9p share of the host /nix/store would hand the guest this whole
  #   repo's rendered config (hostnames, tailnet, IPs, email).
  # - Network: a tap device instead of user-mode (slirp) networking. Slirp
  #   maps 10.0.2.2 to the host's loopback (T3, harmonia, …) and can't be
  #   filtered per VM. The tap is NATed to the internet only; the host
  #   firewall drops guest traffic to private/CGNAT ranges (LAN, tailnet,
  #   docker, the host itself) in the raw table, before Docker's or
  #   Tailscale's FORWARD chains get a say. No IPv6.
  # - Files out: ~/Untrusted is the guest's Downloads (9p, mapped-xattr, so
  #   guest file modes never reach the host: no exec bit on the host side).
  # - Display: virtio-vga without GL (no virglrenderer), no clipboard sharing,
  #   output-only audio (no microphone).
  tap = "tap-untrusted";
  hostIp = "10.231.0.1";
  guestIp = "10.231.0.2";
  outbox = "Untrusted";
  guestUid = 1000; # 9p shows the share root with the host owner's uid
  urlFile = "/run/untrusted-url";
in {
  flake.nixosConfigurations.untrusted-vm = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      ({
        config,
        lib,
        pkgs,
        modulesPath,
        ...
      }: let
        ublock = inputs.firefox-addons.packages.${pkgs.stdenv.hostPlatform.system}.ublock-origin;
        storeImage =
          pkgs.runCommand "untrusted-vm-store.img" {
            nativeBuildInputs = [pkgs.gnutar pkgs.erofs-utils];
          } ''
            tar --create --absolute-names --verbatim-files-from \
              --transform 'flags=rSh;s|/nix/store/||' \
              --files-from ${pkgs.closureInfo {rootPaths = [config.system.build.toplevel];}}/store-paths \
              | mkfs.erofs --quiet -zlz4hc --force-uid=0 --force-gid=0 \
                  -L nix-store -T 0 --hard-dereference --tar=f "$out"
          '';
        launch = pkgs.writeShellScript "untrusted-firefox" ''
          url=$(cat ${urlFile} 2>/dev/null || true)
          exec /run/current-system/sw/bin/firefox ''${url:+"$url"}
        '';
      in {
        imports = [
          (modulesPath + "/virtualisation/qemu-vm.nix")
          (modulesPath + "/profiles/qemu-guest.nix")
          (modulesPath + "/profiles/minimal.nix")
        ];

        nixpkgs.hostPlatform = "x86_64-linux";
        system.stateVersion = "26.05";
        networking.hostName = "untrusted-vm";

        virtualisation = {
          diskImage = null;
          mountHostNixStore = false;
          useNixStoreImage = false;
          memorySize = 4096;
          cores = 4;
          fileSystems."/nix/store" = {
            device = "/dev/disk/by-label/nix-store";
            fsType = "erofs";
            neededForBoot = true;
            options = ["ro"];
          };
          qemu.drives = [
            {
              name = "nix-store";
              file = "${storeImage}";
              driveExtraOpts = {
                format = "raw";
                readonly = "on";
              };
            }
          ];
          # Drops the default xchg/shared dirs too.
          sharedDirectories = lib.mkForce {
            outbox = {
              source = ''"$HOME"/${outbox}'';
              target = "/home/browser/Downloads";
              securityModel = "mapped-xattr";
            };
          };
          qemu.networkingOptions = lib.mkForce [
            "-netdev tap,id=net0,ifname=${tap},script=no,downscript=no"
            "-device virtio-net-pci,netdev=net0"
          ];
          qemu.options = [
            "-vga none"
            "-device virtio-vga"
            "-display gtk,show-menubar=off"
            "-audiodev pipewire,id=snd0"
            "-device intel-hda"
            "-device hda-output,audiodev=snd0"
          ];
        };
        boot.initrd.supportedFilesystems = ["erofs"];
        nix.enable = false; # also skips qemu-vm's register-nix-paths

        networking = {
          useDHCP = false;
          usePredictableInterfaceNames = false;
          enableIPv6 = false;
          interfaces.eth0.ipv4.addresses = [
            {
              address = guestIp;
              prefixLength = 30;
            }
          ];
          defaultGateway = hostIp;
          nameservers = ["9.9.9.9" "149.112.112.112"];
        };

        users.users.browser = {
          isNormalUser = true;
          uid = guestUid;
        };

        # The launcher passes the URL via fw_cfg; only root can read it there.
        boot.kernelModules = ["qemu_fw_cfg"];
        systemd.services.untrusted-url = {
          wantedBy = ["cage-tty1.service"];
          before = ["cage-tty1.service"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            f=/sys/firmware/qemu_fw_cfg/by_name/opt/untrusted/url/raw
            if [ -r "$f" ]; then install -m 0644 "$f" ${urlFile}; fi
          '';
        };

        services.cage = {
          enable = true;
          user = "browser";
          program = launch;
        };
        # Closing Firefox powers the VM off (and QEMU's window with it).
        systemd.services.cage-tty1.unitConfig = {
          OnSuccess = "poweroff.target";
          OnFailure = "poweroff.target";
        };

        services.pipewire = {
          enable = true;
          pulse.enable = true;
        };
        security.rtkit.enable = true;

        programs.firefox = {
          enable = true;
          policies = {
            DisableTelemetry = true;
            DisableFirefoxStudies = true;
            DisableFirefoxAccounts = true;
            DontCheckDefaultBrowser = true;
            NoDefaultBookmarks = true;
            OverrideFirstRunPage = "";
            OverridePostUpdatePage = "";
            UserMessaging.SkipOnboarding = true;
            # Nothing typed here should be kept, and nothing should be typed.
            PasswordManagerEnabled = false;
            OfferToSaveLogins = false;
            HttpsOnlyMode = "enabled";
            DNSOverHTTPS = {
              Enabled = true;
              ProviderURL = "https://dns.quad9.net/dns-query";
              Fallback = true;
            };
            DownloadDirectory = "/home/browser/Downloads";
            PromptForDownloadLocation = false;
            # Throwaway session: quitting should never ask first.
            Preferences = {
              "browser.warnOnQuit" = {
                Value = false;
                Status = "locked";
              };
              "browser.warnOnQuitShortcut" = {
                Value = false;
                Status = "locked";
              };
            };
            ExtensionSettings."uBlock0@raymondhill.net" = {
              installation_mode = "force_installed";
              install_url = "file://${ublock}/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}/uBlock0@raymondhill.net.xpi";
            };
          };
        };
      })
    ];
  };

  flake.nixosModules.untrusted-browser = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    vmConfig = self.nixosConfigurations.untrusted-vm.config;
    launcher = pkgs.writeShellApplication {
      name = "browse-untrusted";
      runtimeInputs = [pkgs.coreutils];
      text = ''
        # browse-untrusted [url]: throwaway Firefox VM
        # (features/untrusted-browser.nix). Downloads land in ~/${outbox}.
        mkdir -p "$HOME/${outbox}"
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        printf '%s' "''${1:-about:blank}" >"$tmp/url"
        TMPDIR=$tmp USE_TMPDIR=1 \
          ${vmConfig.system.build.vm}/bin/run-${vmConfig.system.name}-vm \
          -fw_cfg "name=opt/untrusted/url,file=$tmp/url"
      '';
    };
    # Everything that isn't the public internet, as seen from the guest.
    blocked = [
      "0.0.0.0/8"
      "10.0.0.0/8" # includes the host side of the tap
      "100.64.0.0/10" # CGNAT: the tailnet
      "127.0.0.0/8"
      "169.254.0.0/16"
      "172.16.0.0/12" # docker
      "192.0.0.0/24"
      "192.168.0.0/16"
      "198.18.0.0/15"
      "224.0.0.0/4"
      "240.0.0.0/4"
    ];
  in {
    environment.systemPackages = [launcher];
    home-manager.users.${user}.xdg.desktopEntries.browse-untrusted = {
      name = "Untrusted Browser";
      genericName = "Disposable Firefox VM";
      comment = "Firefox in a throwaway VM; downloads land in ~/${outbox}";
      exec = lib.getExe launcher;
      icon = "firefox";
      categories = ["Network" "WebBrowser"];
    };

    networking.interfaces.${tap} = {
      virtual = true;
      virtualType = "tap";
      virtualOwner = user;
      ipv4.addresses = [
        {
          address = hostIp;
          prefixLength = 30;
        }
      ];
    };
    networking.networkmanager.unmanaged = [tap];
    boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = true;

    # iptables backend (networking.nftables is off). Own chains, re-created
    # on every firewall (re)start; the jumps are removed first so reloads
    # don't stack them.
    networking.firewall.extraCommands = ''
      # untrusted-browser: guest -> public internet only
      iptables -w -t raw -N untrusted-pre 2>/dev/null || iptables -w -t raw -F untrusted-pre
      iptables -w -t raw -D PREROUTING -i ${tap} -j untrusted-pre 2>/dev/null || true
      iptables -w -t raw -I PREROUTING -i ${tap} -j untrusted-pre
      iptables -w -t raw -A untrusted-pre ! -s ${guestIp} -j DROP
      for net in ${toString blocked}; do
        iptables -w -t raw -A untrusted-pre -d "$net" -j DROP
      done
      ip6tables -w -t raw -D PREROUTING -i ${tap} -j DROP 2>/dev/null || true
      ip6tables -w -t raw -I PREROUTING -i ${tap} -j DROP

      # The host's own public addresses (if any) aren't in the list above.
      iptables -w -I nixos-fw -i ${tap} -j DROP

      iptables -w -N untrusted-fwd 2>/dev/null || iptables -w -F untrusted-fwd
      iptables -w -D FORWARD -j untrusted-fwd 2>/dev/null || true
      iptables -w -I FORWARD -j untrusted-fwd
      iptables -w -A untrusted-fwd -i ${tap} -j ACCEPT
      iptables -w -A untrusted-fwd -o ${tap} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
      iptables -w -A untrusted-fwd -o ${tap} -j DROP

      iptables -w -t nat -N untrusted-nat 2>/dev/null || iptables -w -t nat -F untrusted-nat
      iptables -w -t nat -D POSTROUTING -j untrusted-nat 2>/dev/null || true
      iptables -w -t nat -A POSTROUTING -j untrusted-nat
      iptables -w -t nat -A untrusted-nat -s ${guestIp} ! -o ${tap} -j MASQUERADE
    '';
    networking.firewall.extraStopCommands = ''
      iptables -w -t raw -D PREROUTING -i ${tap} -j untrusted-pre 2>/dev/null || true
      ip6tables -w -t raw -D PREROUTING -i ${tap} -j DROP 2>/dev/null || true
      iptables -w -D FORWARD -j untrusted-fwd 2>/dev/null || true
      iptables -w -t nat -D POSTROUTING -j untrusted-nat 2>/dev/null || true
    '';

    persistance.data.directories = [outbox];
  };
}
