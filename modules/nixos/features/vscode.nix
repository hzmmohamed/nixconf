{...}: {
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
    ];

    vscodium = pkgs.vscode-with-extensions.override {
      vscode = pkgs.vscodium;
      vscodeExtensions = extensions;
    };

    settings = builtins.toJSON {
      "workbench.sideBar.location" = "right";
      "workbench.colorTheme" = "Catppuccin Latte";
      "workbench.startupEditor" = "none";
      "files.autoSave" = "afterDelay";
      "files.autoSaveDelay" = 1000;
      "editor.wordWrap" = "on";
      "editor.fontFamily" = "'JetBrainsMono Nerd Font', 'monospace', monospace";
      "nix.serverPath" = "nil";
    };
  in {
    environment.systemPackages = [vscodium];

    home-manager.users.${user}.home.file.".config/VSCodium/User/settings.json".text = settings;
  };
}
