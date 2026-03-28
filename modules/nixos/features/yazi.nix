{...}: {
  flake.nixosModules.yazi = {
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    yaziConfig = (pkgs.formats.toml {}).generate "yazi.toml" {
      log.enabled = false;
      manager = {
        show_hidden = false;
        show_symlink = true;
        linemode = "mtime";
        sort_by = "modified";
        sort_dir_first = true;
        sort_reverse = true;
      };
    };
  in {
    environment.systemPackages = with pkgs; [
      yazi
      imagemagick
      poppler-utils
    ];

    hjem.users.${user}.files.".config/yazi/yazi.toml".source = yaziConfig;
  };
}
