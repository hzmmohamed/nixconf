{self, ...}: {
  flake.nixosModules.vscode = {
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    extensions = with pkgs.vscode-extensions; [
      jnoortheen.nix-ide
      kamadorueda.alejandra
      mkhl.direnv
      ms-python.python
      ms-toolsai.jupyter
      foxundermoon.shell-format
      redhat.vscode-yaml
      editorconfig.editorconfig
      catppuccin.catppuccin-vsc
      catppuccin.catppuccin-vsc-icons
      anthropic.claude-code
      mhutchie.git-graph
    ];

    vscodium = pkgs.vscode-with-extensions.override {
      vscode = pkgs.vscodium;
      vscodeExtensions = extensions;
    };

    userSettings = {
      "workbench.sideBar.location" = "right";
      "workbench.colorTheme" = "Catppuccin Latte";
      "workbench.startupEditor" = "none";
      "files.autoSave" = "afterDelay";
      "files.autoSaveDelay" = 1000;
      "editor.wordWrap" = "on";
      "editor.fontFamily" = "'${self.fonts.monospace}', 'monospace', monospace";
      "editor.fontSize" = self.fonts.size;
      "nix.serverPath" = "nil";
    };

    settingsPath = "/home/${user}/.config/VSCodium/User";
  in {
    environment.systemPackages = [vscodium];

    # Write settings.json as a mutable file (not a nix store symlink) so
    # darkman can sed the colorTheme value at runtime for light/dark switching.
    # Re-written on each nixos-rebuild from the Nix-defined defaults above.
    home-manager.users.${user}.home.activation.vscodiumSettings = {
      after = ["writeBoundary"];
      before = [];
      data = ''
        mkdir -p ${settingsPath}
        cat ${pkgs.writeText "vscodium-settings" (builtins.toJSON userSettings)} \
          | ${pkgs.jq}/bin/jq --monochrome-output > ${settingsPath}/settings.json
      '';
    };
  };
}
