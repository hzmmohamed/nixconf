{inputs, ...}: {
  perSystem = {
    pkgs,
    system,
    ...
  }: {
    # Devenv development shell
    devenv.shells.default = {
      packages =
        (with pkgs; [
          # nix tools
          nil
          nixd
          statix
          deadnix
          nix-tree
          nix-diff
          nix-output-monitor

          # secrets
          sops
          age

          # general
          git
        ])
        ++ [
          inputs.claude-code.packages.${system}.claude-code-bun
        ];

      enterShell = ''
        alias claude=claude-bun

        echo "nixconf devshell"
        echo ""
        echo "  sops secrets/<host>/<name>.yaml   — edit/create secrets"
        echo "  nix flake show                    — list all outputs"
        echo "  nix build .#nixosConfigurations.<host>.config.system.build.toplevel — build a host"
        echo "  treefmt                           — format all files"
        echo ""
      '';

      git-hooks.hooks = {
        alejandra.enable = true;
        deadnix.enable = true;
      };
    };

    # Treefmt configuration
    treefmt.config = {
      projectRootFile = "flake.nix";
      programs.alejandra.enable = true;
    };
  };
}
