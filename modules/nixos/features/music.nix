# Music production stack (DAW, synths, plugins, yabridge) and the audio
# plugin search paths. One switch, off by default:
#   preferences.music.enable = true;
{...}: {
  flake.nixosModules.music = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    home = config.users.users.${user}.home;
  in {
    options.preferences.music.enable =
      lib.mkEnableOption "the music production stack (Ardour, Audacity, Carla, plugins, yabridge)";

    config = lib.mkIf config.preferences.music.enable {
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
  };
}
