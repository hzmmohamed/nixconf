{
  inputs,
  lib,
  ...
}: {
  perSystem = {
    pkgs,
    self',
    ...
  }: let
    lf = self'.packages.lf;
    fishConf =
      pkgs.writeText "fishy-fishy"
      # fish
      ''
        function fish_prompt
            string join "" -- (set_color red) "[" (set_color yellow) $USER (set_color green) "@" (set_color blue) $hostname (set_color magenta) " " $(prompt_pwd) (set_color red) ']' (set_color normal) "\$ "
        end

        set fish_greeting

        # Aliases
        alias rm "rm -i"
        alias cp "cp -i"
        alias mv "mv -i"
        alias mkdir "mkdir -p"

        # Abbreviations
        abbr -a g git
        abbr -a o open
        abbr -a lg lazygit
        abbr -a kc kubectl
        abbr -a kx kubectx
        abbr -a cl clear
        abbr -a yz yazi
        abbr -a zj zellij
        abbr -a jtl journalctl
        abbr -a stl systemctl

        fish_vi_key_bindings

        ${lib.getExe pkgs.zoxide} init fish | source

        function lf --wraps="lf" --description="lf - Terminal file manager (changing directory on exit)"
            cd "$(command lf -print-last-dir $argv)"
        end

        if type -q direnv
            direnv hook fish | source
        end
      '';
  in {
    packages.fish = inputs.wrappers.lib.wrapPackage {
      inherit pkgs;
      package = pkgs.fish;
      runtimeInputs = [
        pkgs.zoxide
      ];
      flags = {
        "-C" = "source ${fishConf}";
      };
    };
  };
}
