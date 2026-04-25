{self, ...}: {
  flake.nixosModules.media = {pkgs, ...}: {
    environment.systemPackages = with pkgs; [
      mpv
      vlc
      handbrake
      digikam
      exiftool
      yt-dlp
      ffmpeg
      self.packages.${pkgs.system}.ffflow
      playerctl
    ];

    services.playerctld.enable = true;
  };
}
