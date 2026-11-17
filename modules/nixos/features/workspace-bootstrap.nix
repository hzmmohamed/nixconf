# Workspace bootstrap for agent hosts that start empty (fern; design:
# docs/plans/2026-11-17-aws-agent-host.md §6). A user oneshot, on every boot,
# idempotent:
#   1. clones each missing project from its remote (the option, else the sops
#      `remotes` file: `<name> <url>` lines, so work URLs stay out of this
#      public repo);
#   2. pins that checkout to the host's git SSH key (`core.sshCommand`), a
#      read-only GitLab deploy key by default;
#   3. reference repos: if the checkout has `.agents/reference-repos.txt`
#      (`name url [ref]`), shallow-clones them into `referenceDir`, makes it
#      read-only, and links `<project>/.repos -> referenceDir` when the project
#      has no `.repos` yet (docs/plans/2026-11-17-repo-size-and-parallelism.md §3.1);
#   4. re-runs `t3code-projects` (agent-t3code) when something was cloned.
#
# Secrets: secrets/<host>/workspace.yaml, keys `git-ssh-key` (private key,
# PEM/OpenSSH) and `remotes`, written by scripts/fern/deploy-key.sh.
# Skipped with a warning while the file is missing.
{...}: {
  flake.nixosModules.workspace-bootstrap = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.workspace;
    user = config.preferences.user.name;
    home = config.users.users.${user}.home;
    host = config.networking.hostName;
    sopsFile = ../../.. + "/secrets/${host}/workspace.yaml";
    haveSops = builtins.pathExists sopsFile;
    keyPath =
      if haveSops
      then config.sops.secrets."workspace-git-ssh-key".path
      else "";
    remotesPath =
      if haveSops
      then config.sops.secrets."workspace-remotes".path
      else "";

    projectLines = lib.concatMapStrings (p: "${p.name}\t${p.path}\t${
      if p.remote == null
      then "-"
      else p.remote
    }\t${p.referenceDir}\n") (lib.attrValues cfg.projects);

    bootstrap = pkgs.writeShellApplication {
      name = "workspace-bootstrap";
      runtimeInputs = with pkgs; [git openssh coreutils gawk systemd];
      text = ''
        key=${lib.escapeShellArg keyPath}
        remotes=${lib.escapeShellArg remotesPath}
        ssh_cmd="ssh -o StrictHostKeyChecking=accept-new"
        if [ -n "$key" ] && [ -r "$key" ]; then
          ssh_cmd="ssh -i $key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
        fi
        export GIT_SSH_COMMAND="$ssh_cmd"
        cloned=0
        failed=0

        lookup_remote() {
          [ -n "$remotes" ] && [ -r "$remotes" ] || return 0
          awk -v n="$1" '$1 == n {print $2; exit}' "$remotes"
        }

        sync_refs() {
          local repo=$1 refdir=$2 manifest=$1/.agents/reference-repos.txt name url ref
          [ -r "$manifest" ] || return 0
          mkdir -p "$refdir"
          chmod u+w "$refdir"
          while read -r name url ref; do
            case "$name" in "" | "#"*) continue ;; esac
            [ -e "$refdir/$name" ] && continue
            echo "workspace: reference $name"
            if [ -n "''${ref:-}" ]; then
              git init -q "$refdir/$name"
              git -C "$refdir/$name" remote add origin "$url"
              git -C "$refdir/$name" fetch -q --depth 1 --filter=blob:none origin "$ref" &&
                git -C "$refdir/$name" checkout -q FETCH_HEAD ||
                echo "workspace: reference $name failed" >&2
            else
              git clone -q --depth 1 --filter=blob:none "$url" "$refdir/$name" ||
                echo "workspace: reference $name failed" >&2
            fi
          done <"$manifest"
          # Documentation for agents, not a build tree (no `pnpm install` in there).
          chmod -R a-w "$refdir"/* 2>/dev/null || true
          if [ ! -e "$repo/.repos" ] && [ ! -L "$repo/.repos" ]; then
            ln -s "$refdir" "$repo/.repos"
          fi
        }

        while IFS=$'\t' read -r name path remote refdir; do
          [ -n "$name" ] || continue
          if [ ! -d "$path/.git" ]; then
            [ "$remote" = "-" ] && remote=$(lookup_remote "$name")
            if [ -z "$remote" ]; then
              echo "workspace: $name has no remote (option or sops remotes); skipping" >&2
              continue
            fi
            echo "workspace: cloning $name into $path"
            mkdir -p "$(dirname "$path")"
            if ! git clone -q "$remote" "$path"; then
              echo "workspace: clone of $name failed" >&2
              failed=1
              continue
            fi
            cloned=1
          fi
          if [ -n "$key" ]; then
            git -C "$path" config core.sshCommand "$ssh_cmd"
          fi
          sync_refs "$path" "$refdir"
        done <<'EOF'
        ${projectLines}EOF

        if [ "$cloned" = 1 ] && systemctl --user cat t3code-projects.service >/dev/null 2>&1; then
          systemctl --user start t3code-projects.service || true
        fi
        # Non-zero → systemd retries (network or GitLab not up yet at boot).
        exit "$failed"
      '';
    };
  in {
    options.preferences.workspace.projects = lib.mkOption {
      default = {};
      description = "Project checkouts this host creates on first boot.";
      type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Key in the sops `remotes` file.";
          };
          path = lib.mkOption {
            type = lib.types.str;
            description = "Absolute checkout path.";
          };
          remote = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Clone URL. null = look it up in the sops `remotes` file (keeps private URLs out of git).";
          };
          referenceDir = lib.mkOption {
            type = lib.types.str;
            default = "${home}/.local/share/reference-repos";
            description = "Shared, read-only directory for the project's reference repos (`.repos` symlink target).";
          };
          packages = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [];
            description = "Extra tools for this project, added to the user profile.";
          };
        };
      }));
    };

    config = lib.mkIf (cfg.projects != {}) {
      warnings =
        lib.optional (!haveSops)
        "workspace-bootstrap: secrets/${host}/workspace.yaml is missing or not git-added; cloning without the deploy key and without sops remotes.";

      sops.secrets = lib.mkIf haveSops {
        "workspace-git-ssh-key" = {
          inherit sopsFile;
          key = "git-ssh-key";
          owner = user;
          mode = "0400";
        };
        "workspace-remotes" = {
          inherit sopsFile;
          key = "remotes";
          owner = user;
        };
      };

      # The forges' published host keys: first clones need no TOFU.
      programs.ssh.knownHosts = {
        "gitlab.com".publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf";
        "github.com".publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
      };

      home-manager.users.${user} = {
        home.packages = lib.unique (lib.concatMap (p: p.packages) (lib.attrValues cfg.projects));

        systemd.user.services.workspace-bootstrap = {
          Unit = {
            Description = "Clone work projects and reference repos";
            # User managers can't order after the system's network-online:
            # retry instead.
            StartLimitIntervalSec = 1800;
            StartLimitBurst = 10;
          };
          Service = {
            Type = "oneshot";
            ExecStart = lib.getExe bootstrap;
            TimeoutStartSec = "30min";
            Restart = "on-failure";
            RestartSec = 60;
          };
          Install.WantedBy = ["default.target"];
        };
      };
    };
  };
}
