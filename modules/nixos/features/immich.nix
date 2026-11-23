{
  inputs,
  self,
  ...
}: {
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
  # Media stays plain files under `mediaLocation` (lock-in guard: the storage
  # template below gives library/<user>/2026/2026-11-22/IMG_….jpg). Settings
  # are declarative (the web settings page is read-only); keys not set here
  # keep Immich's defaults. Published on the tailnet by `tailscale serve`
  # (HTTPS, MagicDNS cert) when the host runs Tailscale; never Funnel.
  flake.nixosModules.immich = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.immich;
    unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
    hostName = config.networking.hostName;
    tailnetName = (self.hosts.${hostName} or {}).tailnetName or hostName;
    port = 2283;
    externalDomain =
      "https://${tailnetName}.${self.tailnet.domain}"
      + lib.optionalString (cfg.tailscaleServePort != 443) ":${toString cfg.tailscaleServePort}";
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

      # Pinned rather than picked by system.stateVersion (butternut's 23.05
      # would get 14, EOL 2026-11): 17 is what VectorChord was checked against
      # above, and the same major on every host keeps the butternut ->
      # peacelily move a plain dump/restore. A host already running another
      # Postgres gets an eval conflict here and has to choose.
      services.postgresql.package = pkgs.postgresql_17;

      services.immich = {
        enable = true;
        package = unstable.immich;
        host = "127.0.0.1";
        inherit port;
        openFirewall = false;
        inherit (cfg) mediaLocation;
        machine-learning.enable = true;
        # Immich 3.4 config-file keys (server/src/dtos/config.dto.ts).
        settings = {
          storageTemplate = {
            enabled = true;
            template = "{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}";
          };
          # Immich's defaults, made explicit: the restic backup (phase 2)
          # runs after this dump.
          backup.database = {
            enabled = true;
            cronExpression = "0 02 * * *";
            keepLastAmount = 14;
          };
          newVersionCheck.enabled = false; # Nix pins the version
          server = {inherit externalDomain;};
          # The ML unit binds `localhost` (module default), so not 127.0.0.1.
          machineLearning.urls = ["http://localhost:3003"];
          # Map tiles load in the *browser*. Immich's default
          # (tiles.immich.cloud, Cloudflare 188.114.96.6/97.6) was unreachable
          # from Cairo Wi-Fi (2026-11-23: TCP and ping dropped, other
          # Cloudflare ranges fine), so the map stayed blank. OpenFreeMap:
          # free, no key, MapLibre styles; style, tiles, fonts and sprites
          # all on tiles.openfreemap.org. No CSP to widen (Immich only sends
          # one with IMMICH_HELMET_FILE).
          map = {
            lightStyle = "https://tiles.openfreemap.org/styles/liberty";
            darkStyle = "https://tiles.openfreemap.org/styles/dark";
          };
        };
      };

      # Publish the loopback service on the tailnet (copied from
      # agent-opencode's opencode-tailscale-serve). Runs as root; the serve
      # config persists in tailscaled state. No Funnel.
      systemd.services.immich-tailscale-serve = lib.mkIf config.services.tailscale.enable {
        description = "Tailscale Serve for Immich";
        after = ["tailscaled.service" "tailscaled-autoconnect.service" "tailscaled-set.service"];
        wants = ["tailscaled.service"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [config.services.tailscale.package pkgs.coreutils];
        script = ''
          for _ in $(seq 60); do
            if tailscale serve --bg --https=${toString cfg.tailscaleServePort} http://127.0.0.1:${toString port}; then
              exit 0
            fi
            sleep 5
          done
          echo "tailscale serve failed (logged in? HTTPS certificates enabled for the tailnet?)" >&2
          exit 1
        '';
      };
    };
  };
}
