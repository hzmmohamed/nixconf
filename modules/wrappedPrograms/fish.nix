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
        set fish_greeting

        ${lib.getExe pkgs.starship} init fish | source

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
        pkgs.starship
      ];
      flags = {
        "-C" = "source ${fishConf}";
      };
    };
  };
}
