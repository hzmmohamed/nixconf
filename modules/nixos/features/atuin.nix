{...}: {
  flake.nixosModules.atuin = {
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
  in {
    environment.systemPackages = [pkgs.atuin];

    home-manager.users.${user}.programs.atuin = {
      enable = true;
      settings = {
        auto_sync = true;
        sync_frequency = "5m";
        sync_address = "https://api.atuin.sh";
        inline_height = 15;
        enter_accept = false;
        keymap_mode = "vim-insert";
        keymap_cursor = {
          emacs = "blink-block";
          vim_insert = "blink-bar";
          vim_normal = "steady-block";
        };
      };
    };
  };
}
