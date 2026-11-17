# Discord via Vesktop. The official (Electron) client duplicates Vesktop and
# is opt-in per host: preferences.discord.officialClient.enable = true;
{
  flake.nixosModules.discord = {
    config,
    lib,
    pkgs,
    ...
  }: {
    options.preferences.discord.officialClient.enable =
      lib.mkEnableOption "the official Discord client alongside Vesktop";

    config = {
      environment.systemPackages =
        [pkgs.vesktop]
        ++ lib.optional config.preferences.discord.officialClient.enable pkgs.discord;

      persistance.cache.directories = [
        ".config/vesktop"
      ];
    };
  };
}
