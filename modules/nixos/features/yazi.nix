{...}: {
  flake.nixosModules.yazi = {
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
  in {
    environment.systemPackages = with pkgs; [
      yazi
      imagemagick
      poppler-utils
    ];

    home-manager.users.${user}.programs.yazi = {
      enable = true;
      settings.log.enabled = false;
      settings.manager = {
        show_hidden = false;
        show_symlink = true;
        linemode = "mtime";
        sort_by = "modified";
        sort_dir_first = true;
        sort_reverse = true;
      };
    };
  };
}
