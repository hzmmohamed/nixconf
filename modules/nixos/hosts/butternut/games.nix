{
  # Non-Steam games on butternut (see preferences.gaming.games in gaming.nix).
  flake.nixosModules.hostButternut = {
    preferences.gaming.games = {
      bioshock-remastered = {
        name = "BioShock Remastered";
        # GOG install in the prefix Lutris created (DXVK already set up).
        prefix = "Games/gog/bioshock-remastered";
        exe = "drive_c/GOG Games/BioShock Remastered/Build/Final/BioshockHD.exe";
        gameId = "umu-409710";
      };
    };
  };
}
