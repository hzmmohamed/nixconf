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

    # PS2: drop your own BIOS dump in ~/Games/ps2/bios/ and your disc dump at
    # ~/Games/ps2/gta-sa.iso (see ~/Games/ps2/README.txt after a switch).
    preferences.gaming.ps2 = {
      enable = true;
      games.gta-sa = {
        name = "GTA San Andreas";
        iso = "gta-sa.iso";
      };
    };
  };
}
