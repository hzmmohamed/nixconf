{...}: {
  # Café-safe firewall: LAN-facing service ports (KDE Connect, spotifyd,
  # Syncthing, Reticulum, mDNS, sshd) are NOT opened globally. Features add
  # them to `preferences.trustedNetworks.allowed*` and they are accepted only on
  #
  #   - tailscale0           (already a trusted interface, tailscale.nix)
  #   - `interfaces`         static list, e.g. butternut's cable port eno2
  #   - trusted connections  a NetworkManager connection whose id is in
  #                          `connections` (home, hotspot, cable, …): an NM
  #                          dispatcher hook marks its interface as trusted
  #                          while it is up
  #
  # On any other Wi-Fi (café, office, an imperative profile) those ports stay
  # closed. Stationary servers set `everywhere = true` and get plain global
  # ports instead.
  #
  # Mechanism (iptables backend, the repo default): the firewall jumps from
  # `nixos-fw` to our own chain `nixos-fw-trusted`, rebuilt by
  # `trusted-networks-apply` from the state directory /run/trusted-networks
  # (one file per trusted interface, written by the dispatcher). Rebuilt on
  # every firewall (re)start too, so `nixos-rebuild switch` keeps the state.
  # Our chain jumps to ACCEPT directly, never to nixos-fw-accept: a reference
  # to a nixos-fw-* chain would make the firewall's own restart fail.
  #
  # Why not firewalld zones: it fights the NixOS firewall module. Why not an
  # extra nftables table: an `accept` there does not override the drop in
  # nixos-fw (every base chain on a hook is evaluated).
  #
  # Trust is by connection id, not SSID: a declarative profile carries the PSK,
  # so an evil twin without it can't associate. Delete imperative duplicates
  # of trusted networks (e.g. a `WE_93CBE9` profile next to `home`): they would
  # come up untrusted.
  #
  # Debug: `ls /run/trusted-networks; doas iptables -S nixos-fw-trusted`.
  flake.nixosModules.trusted-networks = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.trustedNetworks;
    ipt = config.networking.firewall.package;
    stateDir = "/run/trusted-networks";
    chain = "nixos-fw-trusted";

    portType = lib.types.listOf lib.types.port;
    rangeType = lib.types.listOf (lib.types.submodule {
      options = {
        from = lib.mkOption {type = lib.types.port;};
        to = lib.mkOption {type = lib.types.port;};
      };
    });

    rangeStr = r: "${toString r.from}:${toString r.to}";
    rules = lib.unique (
      map (p: "-p tcp --dport ${toString p}") cfg.allowedTCPPorts
      ++ map (r: "-p tcp --dport ${rangeStr r}") cfg.allowedTCPPortRanges
      ++ map (p: "-p udp --dport ${toString p}") cfg.allowedUDPPorts
      ++ map (r: "-p udp --dport ${rangeStr r}") cfg.allowedUDPPortRanges
    );

    apply = pkgs.writeShellApplication {
      name = "trusted-networks-apply";
      runtimeInputs = [ipt pkgs.util-linux pkgs.coreutils];
      text = ''
        exec 9>${stateDir}.lock
        flock 9
        # Firewall not up yet: its start script calls us once the chain exists.
        iptables -w -n -L ${chain} >/dev/null 2>&1 || exit 0
        for cmd in iptables ip6tables; do
          "$cmd" -w -F ${chain} || continue
          for f in ${stateDir}/*; do
            [ -e "$f" ] || continue
            iface=''${f##*/}
            : "$iface"
            ${lib.concatMapStringsSep "\n" (r: ''"$cmd" -w -A ${chain} -i "$iface" ${r} -j ACCEPT'') rules}
          done
        done
      '';
    };

    dispatcher = pkgs.writeShellScript "trusted-networks-dispatcher" ''
      iface=$1
      action=$2
      [ -n "$iface" ] || exit 0
      ${pkgs.coreutils}/bin/mkdir -p ${stateDir}
      case "$action" in
        up | reapply)
          case " ${lib.concatMapStringsSep " " lib.escapeShellArg cfg.connections} " in
            *" $CONNECTION_ID "*) echo "$CONNECTION_ID" > ${stateDir}/"$iface" ;;
            *) ${pkgs.coreutils}/bin/rm -f ${stateDir}/"$iface" ;;
          esac
          ;;
        down | pre-down) ${pkgs.coreutils}/bin/rm -f ${stateDir}/"$iface" ;;
        *) exit 0 ;;
      esac
      ${lib.getExe apply}
    '';
  in {
    options.preferences.trustedNetworks = {
      everywhere = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Open the trusted ports on every interface (stationary servers that
          never leave home: maple, peacelily). Laptops keep this off.
        '';
      };

      connections = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          NetworkManager connection ids treated as trusted. `home` and
          `hotspot` are always added (wifi-home profiles), cable-link adds its
          own profiles. The office profile is deliberately NOT trusted.
        '';
      };

      interfaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["eno2"];
        description = "Interfaces that are always trusted (a cable between own machines).";
      };

      allowedTCPPorts = lib.mkOption {
        type = portType;
        default = [];
      };
      allowedUDPPorts = lib.mkOption {
        type = portType;
        default = [];
      };
      allowedTCPPortRanges = lib.mkOption {
        type = rangeType;
        default = [];
      };
      allowedUDPPortRanges = lib.mkOption {
        type = rangeType;
        default = [];
      };
    };

    config = let
      ports = {
        inherit (cfg) allowedTCPPorts allowedUDPPorts allowedTCPPortRanges allowedUDPPortRanges;
      };
    in
      lib.mkMerge [
        (lib.mkIf cfg.everywhere {networking.firewall = ports;})

        (lib.mkIf (!cfg.everywhere) {
          preferences.trustedNetworks.connections = ["home" "hotspot"];

          assertions = [
            {
              assertion = !config.networking.nftables.enable;
              message = "trusted-networks: only the iptables firewall backend is implemented (set preferences.trustedNetworks.everywhere or port it).";
            }
          ];

          networking.firewall.interfaces = lib.genAttrs cfg.interfaces (_: ports);

          networking.firewall.extraCommands = ''
            ip46tables -N ${chain} 2>/dev/null || true
            ip46tables -A nixos-fw -j ${chain}
            ${lib.getExe apply} || echo "trusted-networks-apply failed" >&2
          '';
          networking.firewall.extraStopCommands = ''
            ip46tables -F ${chain} 2>/dev/null || true
          '';

          networking.networkmanager.dispatcherScripts = lib.mkIf config.networking.networkmanager.enable [
            {
              type = "basic";
              source = dispatcher;
            }
          ];

          environment.systemPackages = [apply];
        })
      ];
  };
}
