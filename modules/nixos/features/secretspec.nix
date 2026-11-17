# secretspec (https://secretspec.dev): per-project secret declaration +
# injection (docs/plans/2026-11-17-secrets-design.md "secretspec").
#
# Projects commit a secretspec.toml with NAMES only and no providers; this
# module writes the machine side, ~/.config/secretspec/config.toml:
#
#   [defaults]  provider = "team", profile = "default"
#   [defaults.providers]
#   team  = where this machine keeps project dev secrets
#   human = human-only secrets (desktops only)
#
#   host kind        team                                    human
#   desktop          keyring:// (Secret Service: gnome-keyring keyring://
#                    today, KeePassXC later)
#   + devVault       kdbx://<home>/VaultDev/dev.kdbx?keyfile=…  keyring://
#   headless (fern)  file:///run/secrets/secretspec          -
#
# On headless hosts `fileSecrets` places sops secrets as
# /run/secrets/secretspec/<project>/<profile>/<KEY> (the file provider's
# layout), owned by the user. Empty by default: d_abm needs none on fern.
#
# AWS credentials are never secretspec values: projects use AWS_PROFILE
# (features/aws.nix SSO profiles; fern's instance role).
#
# Usage, in a checkout: `secretspec check` (lists, prompts for missing
# required values), `secretspec set NAME`, `secretspec run -- <cmd>`.
# The config is a read-only store link: change it here, not with
# `secretspec config global …`.
{inputs, ...}: {
  flake.nixosModules.secretspec = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.secretspec;
    user = config.preferences.user.name;
    home = config.users.users.${user}.home;
    desktop = config.preferences.desktop.enable;
    system = pkgs.stdenv.hostPlatform.system;
    # nixos-26.05 has 0.10.1 (no file/kdbx providers, no aliases); the
    # nixpkgs locked by llm-agents builds 0.21.x.
    package = inputs.llm-agents.inputs.nixpkgs.legacyPackages.${system}.secretspec;

    # sops-nix default secret root (not an option there).
    fileRoot = "/run/secrets/secretspec";
    devVaultUri =
      "kdbx://${cfg.devVault.path}"
      + lib.optionalString (cfg.devVault.keyFile != null) "?keyfile=${cfg.devVault.keyFile}";

    settings = {
      defaults = {
        provider = "team";
        profile = cfg.defaultProfile;
        providers =
          {inherit (cfg) team;}
          // lib.optionalAttrs (cfg.human != null) {inherit (cfg) human;}
          // cfg.extraProviders;
      };
    };
  in {
    options.preferences.secretspec = {
      team = lib.mkOption {
        type = lib.types.str;
        default =
          if cfg.devVault.enable
          then devVaultUri
          else if desktop
          then "keyring://"
          else "file://${fileRoot}";
        defaultText = lib.literalMD ''
          the dev vault (`kdbx://…`) when `devVault.enable`, else `keyring://`
          on desktops, else `file:///run/secrets/secretspec`
        '';
        description = "Provider URI of the `team` alias, the default provider for every project.";
      };
      human = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default =
          if desktop
          then "keyring://"
          else null;
        defaultText = lib.literalExpression ''if desktop then "keyring://" else null'';
        description = "Provider URI of the `human` alias (human-only profiles); null = not defined.";
      };
      extraProviders = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "More `[defaults.providers]` aliases (name -> URI).";
      };
      defaultProfile = lib.mkOption {
        type = lib.types.str;
        default = "default";
        description = "Profile used when neither --profile nor SECRETSPEC_PROFILE is given.";
      };
      devVault = {
        enable = lib.mkEnableOption ''
          the agent-safe dev vault (phase 2: Syncthing folder `vault-dev`,
          KeePassXC database) as the `team` provider
        '';
        path = lib.mkOption {
          type = lib.types.str;
          default = "${home}/VaultDev/dev.kdbx";
          defaultText = lib.literalExpression ''"''${home}/VaultDev/dev.kdbx"'';
          description = "The dev vault database.";
        };
        keyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/run/secrets/vault-dev-keyfile";
          description = "Key file (from sops) that unlocks the dev vault without a password.";
        };
      };
      fileSecrets = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            sopsFile = lib.mkOption {
              type = lib.types.path;
              description = "sops file holding the value.";
            };
            key = lib.mkOption {
              type = lib.types.str;
              description = "Key inside the sops file.";
            };
          };
        });
        default = {};
        example = lib.literalExpression ''
          {"d_abm/default/CAIRO_SIM_ALERT_EMAIL" = {sopsFile = ../../../secrets/fern/secretspec.yaml; key = "d_abm_alert_email";};}
        '';
        description = ''
          `<project>/<profile>/<KEY>` -> sops secret, placed under
          /run/secrets/secretspec for the `file://` provider (user-owned).
        '';
      };
    };

    config = {
      environment.systemPackages = [package];

      # Default sops-nix paths (/run/secrets/secretspec/<name>, a regular file
      # in /run/secrets.d/<n>): the file provider refuses symlinks inside its
      # directory, so no custom `path` here. (A symlinked root is fine.)
      sops.secrets = lib.mapAttrs' (name: s:
        lib.nameValuePair "secretspec/${name}" {
          inherit (s) sopsFile key;
          owner = user;
          mode = "0400";
        })
      cfg.fileSecrets;

      home-manager.users.${user}.xdg.configFile."secretspec/config.toml".source =
        (pkgs.formats.toml {}).generate "secretspec-config.toml" settings;
    };
  };
}
