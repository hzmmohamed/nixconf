# GIS: QGIS desktop. On Sway it is auto-placed on workspace 6
# (preferences.sway.workspaceAssignments, see sway-workspaces.nix).
{
  flake.nixosModules.gis = {pkgs, ...}: {
    environment.systemPackages = [pkgs.qgis];
  };
}
