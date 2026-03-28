{...}: {
  flake.nixosModules.fish = {config, ...}: let
    user = config.preferences.user.name;
  in {
    programs.fish.enable = true;

    home-manager.users.${user} = {
      programs.fish = {
        enable = true;
        shellAliases = {
          rm = "rm -i";
          cp = "cp -i";
          mv = "mv -i";
          mkdir = "mkdir -p";
        };
        shellAbbrs = {
          g = "git";
          o = "open";
          lg = "lazygit";
          kc = "kubectl";
          kx = "kubectx";
          cl = "clear";
          yz = "yazi";
          zj = "zellij";
          jtl = "journalctl";
          stl = "systemctl";
        };
        interactiveShellInit = ''
          set fish_greeting

          fish_vi_key_bindings

          function lf --wraps="lf" --description="lf - Terminal file manager (changing directory on exit)"
              cd "$(command lf -print-last-dir $argv)"
          end

          if type -q direnv
              direnv hook fish | source
          end
        '';
      };

      programs.starship.enable = true;
      programs.zoxide.enable = true;
    };
  };
}
