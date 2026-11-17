# Media tools. mpv + CLI tools are always installed; the heavy GUI apps
# (VLC, HandBrake, digiKam) are opt-in per host — otherwise run them on
# demand with comma, e.g. `, vlc`.
#   preferences.media.extraApps.enable = true;
{self, ...}: {
  flake.nixosModules.media = {
    config,
    lib,
    pkgs,
    ...
  }: {
    options.preferences.media.extraApps.enable =
      lib.mkEnableOption "heavy media GUI apps (VLC, HandBrake, digiKam)";

    config = {
      environment.systemPackages = with pkgs;
        [
          mpv
          exiftool
          yt-dlp
          ffmpeg
          self.packages.${pkgs.stdenv.hostPlatform.system}.ffflow
          playerctl
        ]
        ++ lib.optionals config.preferences.media.extraApps.enable [
          vlc
          handbrake
          digikam
        ];

      services.playerctld.enable = true;
    };
  };
}
