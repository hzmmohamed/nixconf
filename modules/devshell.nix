{inputs, ...}: {
  perSystem = {
    pkgs,
    lib,
    system,
    ...
  }: {
    # Devenv development shell. Use it impurely (`nix develop --impure`, or
    # direnv via .envrc): devenv needs $PWD as its root.
    devenv.shells.default = {
      # Pure evaluation (`nix flake check`, `nix flake show`) has no $PWD and
      # devenv would fail an assertion. Give it a placeholder root there so
      # the flake evaluates; the shell itself is only usable impurely.
      devenv.root = lib.mkIf (builtins.getEnv "PWD" == "") "/var/empty/nixconf-pure-eval";

      # devenv exposes `packages.container-*` for every shell; their default
      # needs nix2container/mk-shell-bin inputs and throws on evaluation,
      # breaking `nix flake show/check`. We do not use devenv containers.
      containers = lib.mkForce {};

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
          just
        ])
        ++ [
          inputs.claude-code.packages.${system}.claude-code
        ];

      enterShell = ''
        alias claude=claude-bun

        echo "nixconf devshell"
        echo ""
        echo "  sops secrets/<host>/<name>.yaml   — edit/create secrets"
        echo "  just fmt | lint | eval <host> | eval-all | check"
        echo "  nix flake show                    — list all outputs"
        echo "  nix build .#nixosConfigurations.<host>.config.system.build.toplevel — build a host"
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
      # Third-party reference clones/submodules: never reformat them.
      settings.global.excludes = [".repos/**"];
    };
  };
}
