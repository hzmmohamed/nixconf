{self, ...}: {
  # Turns the fleet registry (modules/hosts-registry.nix, `self.hosts`) into:
  #
  #   /etc/hosts   <host> <host>.<tailnet>  → tailnet IPv4   (works with MagicDNS off)
  #                <host>-cable             → cable address  (no DNS/mDNS/Tailscale needed)
  #                <host>-lan               → home-LAN address, where reserved
  #   ssh config   /etc/ssh/ssh_config: port, user, one host-key identity
  #                (HostKeyAlias) for every path to a host, and on hosts with a
  #                cable: `ssh <peer>` takes the cable whenever this host has an
  #                address on the cable subnet, the tailnet otherwise
  #   known_hosts  programs.ssh.knownHosts for hosts whose `hostKey` is known
  #                (+ StrictHostKeyChecking yes for them; others stay TOFU)
  #
  # Imported by `general`, so every host gets it.
  flake.nixosModules.hosts-registry = {
    config,
    lib,
    pkgs,
    ...
  }: let
    me = config.networking.hostName;
    user = config.preferences.user.name;
    dom = self.tailnet.domain;
    inherit (self) hosts;
    others = lib.filterAttrs (n: _: n != me) hosts;
    mine = hosts.${me} or {};

    tsName = n: h: h.tailnetName or n;
    has = attr: h: (h.${attr} or null) != null;

    # The cable is a /24 point-to-point link (cable-link.nix).
    cableNet = addr: let
      o = lib.splitString "." addr;
    in "${lib.concatStringsSep "." (lib.take 3 o)}.0/24";

    hostsEntries = lib.mkMerge (lib.flatten (lib.mapAttrsToList (n: h:
      lib.optional (has "ts4" h) {
        ${h.ts4} = lib.unique [n (tsName n h) "${tsName n h}.${dom}"];
      }
      ++ lib.optional (has "lan" h) {${h.lan} = ["${n}-lan"];}
      ++ lib.optional (has "cable" h) {${h.cable} = ["${n}-cable"];})
    others));

    sshHosts = lib.filterAttrs (_: has "sshPort") others;

    # Prefer the cable for the plain name when this host has an address on
    # the peer's cable subnet (link mode, or the peer's shared mode).
    cableMatch = n: h:
      lib.optionalString (has "cable" mine && has "cable" h) ''
        Match originalhost ${n} exec "${pkgs.iproute2}/bin/ip -4 -o addr show to ${cableNet h.cable} | ${pkgs.gnugrep}/bin/grep -q ."
          HostName ${h.cable}
      '';

    hostBlock = n: h: ''
      Host ${lib.concatStringsSep " " (
        [n "${n}.local" "${tsName n h}.${dom}"]
        ++ lib.optional (has "cable" h) "${n}-cable"
        ++ lib.optional (has "lan" h) "${n}-lan"
      )}
        Port ${toString h.sshPort}
        User ${user}
        HostKeyAlias ${n}
      ${lib.optionalString (has "hostKey" h) "  StrictHostKeyChecking yes\n"}'';

    cableHostName = n: h:
      lib.optionalString (has "cable" h) ''
        Host ${n}-cable
          HostName ${h.cable}
      '';

    knownHostNames = n: h: let
      port = toString h.sshPort;
      names =
        [n "${n}.local" "${tsName n h}.${dom}"]
        ++ lib.optional (has "ts4" h) h.ts4
        ++ lib.optional (has "cable" h) h.cable
        ++ lib.optional (has "cable" h) "${n}-cable"
        ++ lib.optional (has "lan" h) h.lan;
    in
      # `n` alone is what HostKeyAlias looks up; the bracketed forms cover
      # direct `ssh -p <port> <addr>` without the config.
      [n] ++ map (x: "[${x}]:${port}") names;
  in {
    networking.hosts = hostsEntries;

    # Order matters: ssh takes the FIRST value it sees, so every Match block
    # (cable HostName) precedes the generic Host blocks.
    programs.ssh.extraConfig = lib.concatStrings (
      lib.mapAttrsToList cableMatch sshHosts
      ++ lib.mapAttrsToList cableHostName sshHosts
      ++ lib.mapAttrsToList hostBlock sshHosts
    );

    programs.ssh.knownHosts = lib.mapAttrs' (n: h:
      lib.nameValuePair "registry-${n}" {
        hostNames = knownHostNames n h;
        publicKey = h.hostKey;
      }) (lib.filterAttrs (_: has "hostKey") sshHosts);
  };
}
