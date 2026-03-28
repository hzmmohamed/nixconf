{...}: {
  flake.nixosModules.music = {
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    home = config.users.users.${user}.home;
  in {
    environment.systemPackages = with pkgs; [
      ardour
      audacity
      carla
      surge-xt
      hydrogen
      lsp-plugins
      x42-plugins
      dragonfly-reverb
      sfizz
      qpwgraph
      yabridge
      yabridgectl
    ];

    # Plugin paths for audio software
    environment.sessionVariables = {
      DSSI_PATH = "${home}/.dssi:${home}/.nix-profile/lib/dssi:/run/current-system/sw/lib/dssi";
      LADSPA_PATH = "${home}/.ladspa:${home}/.nix-profile/lib/ladspa:/run/current-system/sw/lib/ladspa";
      LV2_PATH = "${home}/.lv2:${home}/.nix-profile/lib/lv2:/run/current-system/sw/lib/lv2";
      VST_PATH = "${home}/.vst:${home}/.nix-profile/lib/vst:/run/current-system/sw/lib/vst";
      LXVST_PATH = "${home}/.lxvst:${home}/.nix-profile/lib/lxvst:/run/current-system/sw/lib/lxvst";
    };
  };
}
