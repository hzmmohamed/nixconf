{self, ...}: {
  # `deploy` and `nixconf-sync` system-wide (modules/packages/deploy.nix, which
  # documents both). `just deploy` / `just sync` run the repo's own version
  # through `nix run`, so a freshly edited registry works before a switch.
  #
  #   deploy [--plan] [--dry-run] <host>|all [switch|boot|test|dry-activate]
  #     build where there is room (this machine, the target itself for
  #     `buildOnTarget` hosts, or this machine's registry builder), copy,
  #     activate through a transient systemd unit that survives disconnects.
  #     Deploying the machine you are on switches locally, no ssh.
  #   nixconf-sync [--dry-run]
  #     fetch the other desktops' ~/nixconf, fast-forward main, push the
  #     current branch to a side ref on each (refs/remotes/<me>/<branch>).
  flake.nixosModules.remote-deploy = {pkgs, ...}: let
    pkgs' = self.packages.${pkgs.stdenv.hostPlatform.system};
  in {
    environment.systemPackages = [pkgs'.deploy pkgs'.nixconf-sync];
  };
}
