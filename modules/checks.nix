# Eval-only checks: `nix build .#checks.x86_64-linux.<host>-eval` (or
# `nix flake check`) forces evaluation of every nixosConfiguration without
# building it. The drvPath string has its context discarded, so the check
# derivation does not depend on (and never builds) the system closure.
{
  lib,
  self,
  ...
}: {
  # All hosts are x86_64-linux (the only entry in `systems`).
  perSystem = {pkgs, ...}: {
    checks = lib.mapAttrs' (name: nixos:
      lib.nameValuePair "${name}-eval" (
        pkgs.runCommand "${name}-eval" {} ''
          echo ${builtins.unsafeDiscardStringContext nixos.config.system.build.toplevel.drvPath} > $out
        ''
      ))
    self.nixosConfigurations;
  };
}
