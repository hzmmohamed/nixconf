{...}: {
  # Prometheus + Grafana for the host it runs on (ported from the April
  # `feature/monitoring-stack` branch; plan docs/plans/2026-04-01-monitoring-stack.md
  # on that branch).
  #
  #   Prometheus  127.0.0.1:9090, 30 days, scrapes node / systemd / NVIDIA GPU
  #               exporters (all on 127.0.0.1) and, when llama-swap runs here,
  #               every llama-server's /metrics (fixed ports, ai-server.nix).
  #               Unloaded models show as down targets: that is expected.
  #   Grafana     :3000, tailnet only (firewall: tailscale0). Dashboards: Node
  #               Exporter Full (grafana.com 1860, fetched), NVIDIA GPU
  #               (utkuozdemir exporter) and llama.cpp, from monitoring/dashboards.
  #
  # No sops secrets: Grafana's secret key and the `admin` password are
  # generated on first start under /var/lib/grafana (admin_password is read
  # only when the database is created; change it in the UI afterwards):
  #   doas cat /var/lib/grafana/admin_password
  flake.nixosModules.monitoring = {
    config,
    lib,
    pkgs,
    ...
  }: let
    exporters = config.services.prometheus.exporters;
    grafanaDir = config.services.grafana.dataDir;
    hasNvidia = lib.elem "nvidia" config.services.xserver.videoDrivers;

    # llama-swap models with a fixed upstream (`proxy`), labelled by model name.
    llamaModels =
      lib.optionalAttrs config.services.llama-swap.enable
      (lib.filterAttrs (_: m: m ? proxy) config.services.llama-swap.settings.models);

    local = e: "127.0.0.1:${toString e.port}";

    nodeExporterFull = pkgs.fetchurl {
      name = "node-exporter-full.json";
      url = "https://grafana.com/api/dashboards/1860/revisions/46/download";
      hash = "sha256-5Y3cXcU11MkB+U2pZIvD49Wue2946Y4YW86LKJlhzqM=";
    };

    # Real files, not symlinks: Grafana's file provider walks the directory.
    dashboards = pkgs.runCommand "grafana-dashboards" {} ''
      mkdir $out
      cp ${./monitoring/dashboards}/*.json $out/
      cp ${nodeExporterFull} $out/node-exporter-full.json
    '';
  in {
    services.prometheus = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9090;
      retentionTime = "30d";
      globalConfig.scrape_interval = "15s";

      exporters = {
        node = {
          enable = true;
          listenAddress = "127.0.0.1";
          port = 9100;
          enabledCollectors = ["systemd" "processes"];
        };
        systemd = {
          enable = true;
          listenAddress = "127.0.0.1";
          port = 9558;
        };
        nvidia-gpu = lib.mkIf hasNvidia {
          enable = true;
          listenAddress = "127.0.0.1";
          port = 9835;
        };
      };

      scrapeConfigs =
        [
          {
            job_name = "node";
            static_configs = [{targets = [(local exporters.node)];}];
          }
          {
            job_name = "systemd";
            static_configs = [{targets = [(local exporters.systemd)];}];
          }
        ]
        ++ lib.optional hasNvidia {
          job_name = "nvidia_gpu";
          static_configs = [{targets = [(local exporters.nvidia-gpu)];}];
        }
        ++ lib.optional (llamaModels != {}) {
          job_name = "llama_cpp";
          # `instance` = model name: the llama.cpp dashboard filters by it.
          static_configs =
            lib.mapAttrsToList (name: m: {
              targets = [(lib.removePrefix "http://" m.proxy)];
              labels = {
                instance = name;
                service = "llama-server";
              };
            })
            llamaModels;
        };
    };

    services.grafana = {
      enable = true;
      settings = {
        server = {
          # Tailnet only: 3000 is admitted on tailscale0 alone (below).
          http_addr = "0.0.0.0";
          http_port = 3000;
        };
        security = {
          secret_key = "$__file{${grafanaDir}/secret_key}";
          admin_user = "admin";
          admin_password = "$__file{${grafanaDir}/admin_password}";
        };
        analytics = {
          reporting_enabled = false;
          check_for_updates = false;
        };
      };

      provision = {
        datasources.settings.datasources = [
          {
            name = "Prometheus";
            uid = "prometheus";
            type = "prometheus";
            url = "http://127.0.0.1:${toString config.services.prometheus.port}";
            isDefault = true;
          }
        ];
        dashboards.settings.providers = [
          {
            name = "default";
            options.path = dashboards;
          }
        ];
      };
    };

    # Generated once, never in the Nix store.
    systemd.services.grafana.preStart = lib.mkBefore ''
      for f in secret_key admin_password; do
        if [ ! -s ${grafanaDir}/$f ]; then
          (umask 077; ${lib.getExe pkgs.openssl} rand -hex 32 > ${grafanaDir}/$f)
        fi
      done
    '';

    networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [
      config.services.grafana.settings.server.http_port
    ];
  };
}
