{
  self,
  inputs,
  ...
}: {
  flake.nixosModules.vscode = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;

    # Keep the VSCode extension on the same Claude Code version as the `claude`
    # CLI from the claude-code flake input (the extension bundles its own copy of
    # the binary, so a mismatch means two different Claudes on one machine).
    # When flake.lock bumps claude-code, update vsixPin below: the assert will
    # tell you the new version, then re-prefetch the hash with
    #   nix-prefetch-url "https://anthropic.gallery.vsassets.io/_apis/public/gallery/publisher/anthropic/extension/claude-code/<version>/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage?targetPlatform=linux-x64"
    claudeVersion = inputs.claude-code.packages.${pkgs.stdenv.hostPlatform.system}.claude-code.version;
    vsixPin = {
      version = "2.1.282";
      hash = "sha256-AIchLRsTIDmXnSw2oGJ30ZdYb2IaSgnD1xTfGeLA/bw=";
      arch = "linux-x64";
    };
    claude-code-extension = assert lib.assertMsg (claudeVersion == vsixPin.version)
    ("claude-code CLI is ${claudeVersion} but the VSCode extension is pinned to "
      + "${vsixPin.version}; update vsixPin in modules/nixos/features/vscode.nix");
    # nixpkgs' mktplcRef is not overridable (it is consumed before mkDerivation),
    # so swap version + src directly and keep its autoPatchelf/alsa-lib wiring.
      pkgs.vscode-extensions.anthropic.claude-code.overrideAttrs (_: {
        version = vsixPin.version;
        src = pkgs.fetchurl {
          name = "anthropic-claude-code.vsix";
          url = "https://anthropic.gallery.vsassets.io/_apis/public/gallery/publisher/anthropic/extension/claude-code/${vsixPin.version}/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage?targetPlatform=${vsixPin.arch}";
          inherit (vsixPin) hash;
        };
      });

    extensions =
      (with pkgs.vscode-extensions; [
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
        mhutchie.git-graph
        gitlab.gitlab-workflow
        dbaeumer.vscode-eslint
        esbenp.prettier-vscode
      ])
      ++ [
        claude-code-extension
        (pkgs.vscode-utils.extensionFromVscodeMarketplace {
          publisher = "ActivityWatch";
          name = "aw-watcher-vscode";
          version = "0.5.0";
          sha256 = "sha256-OrdIhgNXpEbLXYVJAx/jpt2c6Qa5jf8FNxqrbu5FfFs=";
        })
        (pkgs.vscode-utils.extensionFromVscodeMarketplace {
          publisher = "oxc";
          name = "oxc-vscode";
          version = "1.52.0";
          sha256 = "sha256-CaUe8WSBc7fPianvGl2VS0fciMAw+kAosZ7L6SwBplY=";
        })
      ];

    vscodium = pkgs.vscode-with-extensions.override {
      vscode = pkgs.vscodium;
      vscodeExtensions = extensions;
    };

    userSettings = {
      "workbench.sideBar.location" = "right";
      # Follow the desktop colour scheme (portal color-scheme, written by
      # theme-mode via dconf) instead of rewriting colorTheme at runtime.
      "window.autoDetectColorScheme" = true;
      "workbench.preferredLightColorTheme" = "Catppuccin Latte";
      "workbench.preferredDarkColorTheme" = "Catppuccin Mocha";
      "workbench.colorTheme" = "Catppuccin Latte";
      "workbench.startupEditor" = "none";
      "files.autoSave" = "afterDelay";
      "files.autoSaveDelay" = 1000;
      "editor.wordWrap" = "on";
      "editor.fontFamily" = "'${self.fonts.monospace}', 'monospace', monospace";
      "editor.fontSize" = self.fonts.size;
      "nix.serverPath" = "nil";
      "password-store" = "gnome-libsecret";
    };

    settingsPath = "/home/${user}/.config/VSCodium/User";
  in {
    environment.systemPackages = [vscodium];

    # Write settings.json as a mutable file (not a nix store symlink) so
    # VSCodium can still save UI changes. Re-written on each nixos-rebuild
    # from the Nix-defined defaults above. Light/dark follows the portal
    # colour scheme (window.autoDetectColorScheme).
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
