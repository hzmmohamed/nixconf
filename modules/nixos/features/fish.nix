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

          # Auto-start zellij for interactive terminals, but not when:
          # - already inside zellij
          # - running inside a non-interactive context (e.g. IDE terminal, scripts)
          # - stdin/stdout aren't a terminal: tools like T3 Code run `fish -ilc`
          #   through pipes to read PATH, and `exec zellij` hijacked that
          # - inside T3 Code's terminal (T3CODE_PROJECT_ROOT): "Run in terminal"
          #   types the command into a fresh pty shell, which zellij swallowed
          if status is-interactive; and isatty stdin; and isatty stdout; and not set -q ZELLIJ; and not set -q INSIDE_EMACS; and not set -q VSCODE_PID; and not set -q T3CODE_PROJECT_ROOT
              exec zellij
          end
        '';
      };

      programs.starship.enable = true;
      programs.zoxide.enable = true;
    };
  };
}
