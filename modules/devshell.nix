{inputs, ...}: {
  perSystem = {
    pkgs,
    system,
    ...
  }: {
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [
        # nix tools
        nil
        nixd
        statix
        alejandra
        deadnix
        nix-tree
        nix-diff
        nix-output-monitor

        # secrets
        sops
        age

        # general
        git
      ];

      shellHook = ''
        echo "nixconf devshell"
        echo ""
        echo "  sops secrets/<host>/<name>.yaml   — edit/create secrets"
        echo "  nix flake show                    — list all outputs"
        echo "  nix build .#nixosConfigurations.<host>.config.system.build.toplevel — build a host"
        echo ""
      '';
    };
  };
}
