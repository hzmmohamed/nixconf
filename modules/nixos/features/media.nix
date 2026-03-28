{...}: {
  flake.nixosModules.media = {
    pkgs,
    ...
  }: {
    environment.systemPackages = with pkgs; [
      mpv
      vlc
      handbrake
      digikam
      exiftool
      yt-dlp
      ffmpeg
      playerctl
    ];

    services.playerctld.enable = true;
  };
}
