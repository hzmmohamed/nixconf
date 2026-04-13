{self, ...}: {
  flake.nixosModules.cad = {
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
  in {
    environment.systemPackages = with pkgs; [
      freecad
      openscad
    ];

    home-manager.users.${user} = {
      home.file.".local/share/FreeCAD/Mod/freecad-ai".source =
        self.packages.${pkgs.system}.freecad-ai + "/share/FreeCAD/Mod/freecad-ai";
    };
  };
}
