{inputs, ...}: {
  flake.nixosModules.nix = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
  in {
    imports = [
      inputs.nix-index-database.nixosModules.nix-index
    ];
    programs.nix-index-database.comma.enable = true;

    programs.direnv = {
      enable = true;
      silent = false;
      loadInNixShell = true;
      direnvrcExtra = "";
      nix-direnv = {
        enable = true;
      };
    };

    nix.settings = {
      experimental-features = ["nix-command" "flakes"];
      trusted-users = ["root" "@wheel"];
      substituters = [
        "https://cache.nixos.org"
        "https://cache.nixos-cuda.org"
        "https://noctalia.cachix.org"
        # llm-agents flake input (agent CLIs: t3code, herdr, opencode, ...)
        "https://cache.numtide.com"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
        "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
        "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
      ];
    };
    # Store hygiene (2026-11-23: butternut's store had reached 1010 GB, 784 GB
    # of it dead: there was no GC at all). Daily timers, Persistent (a run
    # missed while off/asleep happens after boot/wake), only on AC power
    # (laptops never GC on battery; hosts without a battery count as AC).
    # Generations older than 14 days go; the store is deduplicated weekly.
    # Schedules/options are defaults: a host may override (fern: weekly).
    # min-free/max-free: during builds, GC kicks in below 10 GiB free and
    # stops at 50 GiB. Desktop hosts get a notification after each GC with
    # what it freed (the report file + user path unit below).
    nix.gc = {
      automatic = true;
      dates = lib.mkDefault "daily";
      persistent = true;
      randomizedDelaySec = "1h";
      options = lib.mkDefault "--delete-older-than 14d";
    };
    nix.optimise = {
      automatic = true;
      dates = lib.mkDefault ["weekly"];
    };
    nix.settings = {
      min-free = 10 * 1024 * 1024 * 1024;
      max-free = 50 * 1024 * 1024 * 1024;
    };
    systemd.services.nix-gc = {
      unitConfig.ConditionACPower = true;
      # Same command as the module's, plus a one-line report for the
      # notification: nix-collect-garbage ends with "N store paths deleted,
      # X MiB freed".
      script = lib.mkForce ''
        set -o pipefail
        ${config.nix.package.out}/bin/nix-collect-garbage ${config.nix.gc.options} 2>&1 | tee /run/nix-gc/out
        summary=$(grep -E 'store paths deleted' /run/nix-gc/out | tail -n1)
        avail=$(df -h --output=avail /nix/store | tail -n1 | tr -d ' ')
        echo "''${summary:-nothing to delete}; $avail free" > /var/lib/nix-gc/last
      '';
      serviceConfig = {
        RuntimeDirectory = "nix-gc";
        StateDirectory = "nix-gc";
      };
    };
    systemd.services.nix-optimise.unitConfig.ConditionACPower = true;

    home-manager.users.${user} = lib.mkIf config.preferences.desktop.enable {
      systemd.user.paths.nix-gc-notify = {
        Unit.Description = "Watch the Nix GC report";
        Path.PathChanged = "/var/lib/nix-gc/last";
        Install.WantedBy = ["default.target"];
      };
      systemd.user.services.nix-gc-notify = {
        Unit.Description = "Notify about the last Nix garbage collection";
        Service = {
          Type = "oneshot";
          ExecStart = toString (pkgs.writeShellScript "nix-gc-notify" ''
            ${lib.getExe' pkgs.libnotify "notify-send"} -a "Nix" -i user-trash-full \
              "Nix garbage collection" "$(cat /var/lib/nix-gc/last)"
          '');
        };
      };
    };

    programs.nix-ld.enable = true;
    nixpkgs.config.allowUnfree = true;

    environment.systemPackages = with pkgs; [
      # Nix tooling
      nil
      nixd
      statix
      alejandra
      manix
      nix-inspect
    ];
  };
}
