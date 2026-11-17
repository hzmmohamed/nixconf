# AWS CLI, plus (opt-in) AWS IAM Identity Center profiles for the TfC account
# (docs/plans/2026-11-17-aws-sso-runbook.md, secrets design "AWS plan").
#
# preferences.aws.sso.enable renders the SSO part of ~/.aws/config from sops
# (secrets/shared/aws-sso.yaml: account_id, start_url, region; the repo is
# public, so none of them is in Nix code):
#
#   [sso-session tfc]                    one login (`aws-login`) ...
#   [profile tfc-admin]     -> Admin     ... for every profile below
#   [profile tfc-operator]  -> Operator
#   [profile tfc-cloudbox]  -> CloudBox  (cloud-box picks it by default)
#
# How: a sops template (owner = user, 0400, /run/secrets/rendered/aws-sso-config)
# holds that block; `aws-sso-config-sync` (home-manager activation, and every
# `aws-login`) copies it between `# BEGIN/END nixconf aws-sso` markers into
# ~/.aws/config. The rest of the file ([default] region, anything added by
# hand) and ~/.aws/credentials stay untouched and writable. Without the sops
# file the option only warns.
#
# Use a profile per command or per shell: `AWS_PROFILE=tfc-operator …`, or in
# a project's git-ignored .envrc.local. Nothing sets AWS_PROFILE globally, so
# the static `default` keys keep working until they are retired.
{...}: {
  flake.nixosModules.aws = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.aws.sso;
    user = config.preferences.user.name;
    sopsFile = ../../.. + "/secrets/shared/aws-sso.yaml";
    present = builtins.pathExists sopsFile;
    on = cfg.enable && present;
    ph = config.sops.placeholder;
    renderedPath = config.sops.templates."aws-sso-config".path;

    block =
      ''
        [sso-session ${cfg.session}]
        sso_start_url = ${ph."aws-sso-start-url"}
        sso_region = ${ph."aws-sso-region"}
        sso_registration_scopes = sso:account:access
      ''
      + lib.concatStrings (lib.mapAttrsToList (profile: role: ''

          [profile ${profile}]
          sso_session = ${cfg.session}
          sso_account_id = ${ph."aws-sso-account-id"}
          sso_role_name = ${role}
          region = ${ph."aws-sso-region"}
          output = json
        '')
        cfg.profiles);

    configSync = pkgs.writeShellApplication {
      name = "aws-sso-config-sync";
      runtimeInputs = [pkgs.coreutils pkgs.gawk pkgs.diffutils];
      text = ''
        # Copy the rendered SSO block into ~/.aws/config between markers.
        src=${renderedPath}
        if [ ! -r "$src" ]; then
          echo "aws-sso-config-sync: $src missing (sops not set up on this host?); ~/.aws/config untouched" >&2
          exit 0
        fi
        dir="$HOME/.aws"
        f="$dir/config"
        begin="# BEGIN nixconf aws-sso (managed by NixOS: features/aws.nix; edits inside are replaced)"
        end="# END nixconf aws-sso"
        mkdir -p "$dir"
        chmod 700 "$dir"
        rest=""
        if [ -e "$f" ]; then
          # Everything outside the managed block.
          rest=$(awk -v b="# BEGIN nixconf aws-sso" -v e="$end" '
            index($0, b) == 1 { skip = 1; next }
            skip && $0 == e { skip = 0; next }
            !skip { print }
          ' "$f" | cat -s)
        fi
        tmp=$(mktemp "$f.XXXXXX")
        trap 'rm -f "$tmp"' EXIT
        {
          if [ -n "$rest" ]; then printf '%s\n\n' "$rest"; fi
          echo "$begin"
          cat "$src"
          echo "$end"
        } >"$tmp"
        if [ -e "$f" ] && cmp -s "$tmp" "$f"; then exit 0; fi
        chmod 600 "$tmp"
        mv -f "$tmp" "$f"
        trap - EXIT
      '';
    };

    awsLogin = pkgs.writeShellApplication {
      name = "aws-login";
      runtimeInputs = [pkgs.awscli2 pkgs.gnused configSync];
      text = ''
        # aws-login [--use-device-code]: one SSO login for all tfc-* profiles,
        # then who each profile is. (Headless / over ssh: --use-device-code.)
        aws-sso-config-sync
        aws sso login --sso-session ${cfg.session} "$@"
        for p in ${lib.escapeShellArgs (lib.attrNames cfg.profiles)}; do
          printf '%-14s ' "$p"
          aws sts get-caller-identity --profile "$p" --query Arn --output text 2>&1 |
            sed -E 's#.*assumed-role/AWSReservedSSO_([^_]+)_[^/]*/(.*)#\1 as \2#' || true
        done
      '';
    };
  in {
    options.preferences.aws.sso = {
      enable = lib.mkEnableOption ''
        AWS IAM Identity Center profiles in ~/.aws/config, rendered from sops
        (secrets/shared/aws-sso.yaml), plus the `aws-login` helper
      '';
      session = lib.mkOption {
        type = lib.types.str;
        default = "tfc";
        description = "Name of the `[sso-session]` all profiles share (`aws sso login --sso-session <name>`).";
      };
      profiles = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          tfc-admin = "Admin";
          tfc-operator = "Operator";
          tfc-cloudbox = "CloudBox";
        };
        description = ''
          Profile name -> permission set name (sso_role_name). The permission
          sets are created by scripts/aws-sso/setup.sh.
        '';
      };
    };

    config = lib.mkMerge [
      {
        environment.systemPackages = with pkgs; [
          awscli2
          aws-vault
        ];

        environment.variables.AWS_VAULT_BACKEND = "file";

        warnings = lib.optional (cfg.enable && !present) ''
          preferences.aws.sso.enable: secrets/shared/aws-sso.yaml is missing (or not git-added),
          so no SSO profiles are rendered. Create it: bash scripts/aws-sso/store-config.sh
        '';
      }

      (lib.mkIf on {
        sops.secrets = {
          "aws-sso-account-id" = {
            inherit sopsFile;
            key = "account_id";
          };
          "aws-sso-start-url" = {
            inherit sopsFile;
            key = "start_url";
          };
          "aws-sso-region" = {
            inherit sopsFile;
            key = "region";
          };
        };

        sops.templates."aws-sso-config" = {
          content = block;
          owner = user;
          mode = "0400";
        };

        environment.systemPackages = [awsLogin configSync];

        home-manager.users.${user}.home.activation.awsSsoConfig = {
          after = ["writeBoundary"];
          before = [];
          data = "run ${lib.getExe configSync}";
        };
      })
    ];
  };
}
