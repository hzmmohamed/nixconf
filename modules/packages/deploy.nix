# deploy + nixconf-sync: the fleet's deploy and repo-sync commands, with the
# hosts registry (modules/hosts-registry.nix) baked in. perSystem packages so
# that `just deploy` / `just sync` run the repo's CURRENT version
# (`nix run .#deploy`): a new host or builder works before any switch.
# The remote-deploy feature installs both system-wide.
#
#   deploy [--plan] [--dry-run] <host>|all [switch|boot|test|dry-activate]
#   nixconf-sync [--dry-run]
#
# Logic and docs: deploy.sh, nixconf-sync.sh next to this file.
{
  lib,
  self,
  ...
}: let
  inherit (self) hosts;
  has = attr: h: (h.${attr} or null) != null;
  words = lib.concatStringsSep " ";

  # NixOS hosts `deploy` knows: registry entries with sshd and a configuration.
  registryHosts = lib.attrNames (lib.filterAttrs
    (n: h: has "sshPort" h && self.nixosConfigurations ? ${n})
    hosts);
  targetBuildHosts = lib.attrNames (lib.filterAttrs (_: h: h.buildOnTarget or false) hosts);

  # client=builder: the first registry host listing the client in builderFor.
  builders = words (lib.concatLists (lib.mapAttrsToList
    (b: h: map (c: "${c}=${b}") (lib.filter (c: c != b) (h.builderFor or [])))
    hosts));

  # builder=<cache url>|<public key> for builders that serve a signed cache
  # (features/nix-serve.nix, port 5000). The tailnet IP, not the name: the
  # target may run an old config without the registry's /etc/hosts.
  caches =
    words (lib.mapAttrsToList (b: h: "${b}=http://${h.ts4 or b}:5000|${self.nixServeKeys.${b}}")
      (lib.filterAttrs (b: h: (h.builderFor or []) != [] && self.nixServeKeys ? ${b}) hosts));

  # Peers for nixconf-sync: the GUI machines (registry role "desktop").
  syncPeers = lib.attrNames (lib.filterAttrs (_: h: lib.elem "desktop" (h.roles or []) && has "sshPort" h) hosts);

  q = lib.escapeShellArg;
in {
  perSystem = {pkgs, ...}: {
    packages.deploy = pkgs.writeShellApplication {
      name = "deploy";
      runtimeInputs = with pkgs; [openssh coreutils git gnused nix];
      text =
        ''
          registry_hosts=${q (words registryHosts)}
          target_build_hosts=${q (words targetBuildHosts)}
          builders=${q builders}
          caches=${q caches}
          default_user=${q self.user.name}
          default_port=7654
        ''
        + builtins.readFile ./deploy.sh;
    };

    packages.nixconf-sync = pkgs.writeShellApplication {
      name = "nixconf-sync";
      runtimeInputs = with pkgs; [git openssh coreutils];
      text =
        ''
          sync_peers=${q (words syncPeers)}
          default_user=${q self.user.name}
          default_home=${q self.user.home}
          default_port=7654
        ''
        + builtins.readFile ./nixconf-sync.sh;
    };
  };
}
