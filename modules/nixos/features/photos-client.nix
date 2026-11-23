{self, ...}: {
  # "Photos" launcher: the Immich web UI as a standalone Chromium app window
  # (Immich has no desktop app; falls back to the default browser). Desktop
  # hosts only. Design: docs/plans/2026-11-22-photos-immich-design.md.
  #
  # The URL is the server's own `server.externalDomain` (features/immich.nix)
  # on the registry host with role `photos`, so moving the library (phase 3:
  # peacelily behind the Tailscale Service svc:photos) moves the launcher too.
  # It opens /photos (the timeline), which also gives the window its own
  # app_id, chrome-<host>__photos-Default (Chromium drops the port), for the
  # workspace-2 rule in sway-workspaces.nix.
  #
  # immich.svg: Immich's logo (build/www/icon.svg, CC-BY-4.0, immich.app),
  # vendored so desktop hosts don't pull the Immich package for an icon.
  flake.nixosModules.photos-client = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    serverHost =
      lib.findFirst (n: lib.elem "photos" (self.hosts.${n}.roles or [])) null
      (lib.attrNames self.hosts);
    url =
      lib.optionalString (serverHost != null)
      "${self.nixosConfigurations.${serverHost}.config.services.immich.settings.server.externalDomain}/photos";
    hmChromium = config.home-manager.users.${user}.programs.chromium;

    photosOpen = pkgs.writeShellApplication {
      name = "photos-open";
      runtimeInputs = [pkgs.xdg-utils];
      text =
        if hmChromium.enable
        then ''exec ${lib.getExe hmChromium.finalPackage} --app=${lib.escapeShellArg url}''
        else ''exec xdg-open ${lib.escapeShellArg url}'';
    };
  in {
    config = lib.mkIf config.preferences.desktop.enable {
      assertions = [
        {
          assertion = serverHost != null;
          message = "photos-client: no host in modules/hosts-registry.nix has the `photos` role.";
        }
      ];

      home-manager.users.${user} = {
        home.packages = [photosOpen];
        xdg.desktopEntries.photos = {
          name = "Photos";
          genericName = "Photo library (Immich)";
          exec = lib.getExe photosOpen;
          icon = "${./photos-client/immich.svg}";
          categories = ["Graphics" "Photography"];
        };
      };
    };
  };
}
