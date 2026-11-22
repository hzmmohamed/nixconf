{inputs, ...}: {
  # Immich (photo/video library, phone backup), on loopback.
  # Design: docs/plans/2026-11-22-photos-immich-design.md.
  #
  # Why nixpkgs-unstable: 26.05 ships Immich 2.7.5; the phone app is 3.x and a
  # v2 library would need a v2→v3 migration later. The module *and* the
  # package come from unstable (the 26.05 module lags 3.x). Postgres, its
  # pgvector/VectorChord extensions and Redis stay on 26.05's packages, as the
  # module wires them: Postgres 17, VectorChord 1.1.1, pgvector 0.8.2 sit
  # inside Immich 3.4's accepted ranges (>=14, >=0.3 <2, >=0.5 <1). The ML
  # service runs `cfg.package.machine-learning`, so it follows the package.
  # Drop the override (disabledModules, imports, package) once the release
  # branch ships >= 3.x (26.11).
  #
  # Media stays plain files under `mediaLocation` (lock-in guard).
  flake.nixosModules.immich = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.immich;
    unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  in {
    disabledModules = ["services/web-apps/immich.nix"];
    imports = ["${inputs.nixpkgs-unstable}/nixos/modules/services/web-apps/immich.nix"];

    options.preferences.immich = {
      mediaLocation = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/immich";
        description = ''
          Library root (originals, thumbnails, DB dumps). The same path on
          every host, so a migration is a plain copy/restore.
        '';
      };
      tailscaleServePort = lib.mkOption {
        type = lib.types.port;
        default = 443;
        description = "HTTPS port `tailscale serve` publishes Immich on.";
      };
      cuda = lib.mkEnableOption "CUDA onnxruntime for Immich's machine learning";
    };

    config = {
      assertions = [
        {
          assertion = !cfg.cuda;
          message = "preferences.immich.cuda is not implemented yet (phase 3 of docs/plans/2026-11-22-photos-immich-plan.md).";
        }
      ];

      services.immich = {
        enable = true;
        package = unstable.immich;
        host = "127.0.0.1";
        port = 2283;
        openFirewall = false;
        inherit (cfg) mediaLocation;
        machine-learning.enable = true;
      };
    };
  };
}
