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

        # general
        git
      ];

      shellHook = ''
        echo "nixconf devshell"
      '';
    };
  };
}
