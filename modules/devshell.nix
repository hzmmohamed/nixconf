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
        # Install pre-commit hook for formatting
        if [ -d .git ]; then
          cat > .git/hooks/pre-commit << 'HOOK'
        #!/usr/bin/env bash
        # Format staged .nix files with alejandra
        staged=$(git diff --cached --name-only --diff-filter=ACM -- '*.nix')
        if [ -n "$staged" ]; then
          echo "$staged" | xargs alejandra -q
          echo "$staged" | xargs git add
        fi
        HOOK
          chmod +x .git/hooks/pre-commit
        fi

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
