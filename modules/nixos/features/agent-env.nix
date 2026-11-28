# Network-aware agent tooling: `agent-net` reports whether the current
# connection is metered (so later tasks — nx's download budget,
# agent-devshell — can behave on a phone hotspot). Contributes to
# `flake.nixosModules.agent-common` (see agent-common.nix for the rest of
# that module; files are merged the same way modules/nixos/hosts/butternut/*.nix
# all contribute to `hostButternut`).
{self, ...}: {
  flake.nixosModules.agent-common = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;

    # Wrap a bare-stdlib Python script as a CLI. `--suffix PATH` (never
    # `--prefix`) so the tool's own deps never shadow the user's or the dev
    # shell's PATH; later tasks (`nx`, `agent-devshell`) reuse this.
    mkToolWith = extraArgs: name: script: deps:
      pkgs.runCommand name {
        nativeBuildInputs = [pkgs.makeWrapper];
        meta.mainProgram = name;
      } ''
        makeWrapper ${pkgs.python3}/bin/python3 $out/bin/${name} \
          --add-flags ${script} \
          --suffix PATH : ${lib.makeBinPath deps} ${lib.escapeShellArgs extraArgs}
      '';
    mkTool = mkToolWith [];

    # A flake package (modules/packages/agent-net.nix): attn takes it too.
    agentNet = self.packages.${pkgs.stdenv.hostPlatform.system}.agent-net;
    # agent-git: where an agent stands in git (worktree/branch/dirty) for the
    # SessionStart hook, a Stop hook that catches uncommitted thread work,
    # and `agent-push` (thread branch only) since `git push` stays denied.
    agentGit = mkTool "agent-git" ./agent-env/agent_git.py [pkgs.git pkgs.gh];
    agentPush = pkgs.writeShellScriptBin "agent-push" ''
      exec ${lib.getExe agentGit} push "$@"
    '';
    # nx: store-first tool runner. nix-index supplies nix-locate (attribute
    # lookup when a bare prog name doesn't match its own nixpkgs attribute);
    # agentNet is its own metered/unmetered/offline source.
    nx = mkTool "nx" ./agent-env/nx.py [pkgs.nix pkgs.nix-index agentNet];
    # agent-devshell: wraps a provider binary so it starts inside the
    # project's direnv dev shell when one is cached and allowed (T3 Code's
    # Claude/OpenCode instances point at claude-devshell/opencode-devshell,
    # below). Never fails closed: it always execs the binary it's given.
    #
    # DIRENV_CONFIG: NixOS's programs.direnv only exports it to login shells
    # (environment.variables); T3's systemd service has none, so direnv
    # would use its built-in use_flake (a full `nix print-dev-env` per call,
    # a layout the cache check never sees). Default it to /etc/direnv
    # (nix-direnv's direnvrc) unless the caller already set one; the
    # warm-up forwards it to its systemd-run unit.
    agentDevshell =
      mkToolWith
      (lib.optionals config.programs.direnv.enable ["--set-default" "DIRENV_CONFIG" "/etc/direnv"])
      "agent-devshell"
      ./agent-env/agent_devshell.py [pkgs.direnv pkgs.git pkgs.systemd agentNet];

    # The one Markdown file every agent reads (Claude via a CLAUDE.md import
    # line, OpenCode via its `instructions` config, Codex CLI as its global
    # ~/.codex/AGENTS.md: Codex has no imports). Store path, world-readable
    # like the rest of $XDG_CONFIG_HOME.
    guidelinesFile = ./agent-env/guidelines.md;

    # Claude config dirs (relative to $HOME), one per subscription. Mirrors
    # agent-common's own `accountDirs` (not exposed from there: features stay
    # independent, and this is the only other place that needs it).
    accountDirs = lib.unique (lib.mapAttrsToList (_: a: a.configDir) config.preferences.agents.claudeAccounts);

    # Appends the `@~/.config/agents/guidelines.md` import line to every
    # account's CLAUDE.md (idempotent, never rewrites the rest of the file).
    guidelinesImport = pkgs.writeShellApplication {
      name = "agent-guidelines-import";
      runtimeInputs = [pkgs.coreutils pkgs.gnugrep];
      text = builtins.readFile ./agent-env/guidelines-import.sh;
    };

    userBin = "/etc/profiles/per-user/${user}/bin";
    claudeDevshell = pkgs.writeShellScriptBin "claude-devshell" ''
      exec ${lib.getExe agentDevshell} ${userBin}/claude "$@"
    '';
    opencodeDevshell = pkgs.writeShellScriptBin "opencode-devshell" ''
      exec ${lib.getExe agentDevshell} ${userBin}/opencode "$@"
    '';
  in {
    options.preferences.agents.guidelinesFile = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = guidelinesFile;
      description = "Store path of the shared agent guidelines markdown (installed at ~/.config/agents/guidelines.md).";
    };

    config = {
      home-manager.users.${user} = {
        home.packages = [agentNet agentGit agentPush nx agentDevshell claudeDevshell opencodeDevshell];

        xdg.configFile."agents/guidelines.md".source = guidelinesFile;
        # Codex reads $CODEX_HOME/AGENTS.md (default ~/.codex) verbatim.
        home.file.".codex/AGENTS.md".source = guidelinesFile;

        # (NixOS lib has no lib.hm: spell out the DAG entry, like agent-common's
        # claudeSettingsMerge.)
        home.activation.agentGuidelinesImport = {
          after = ["writeBoundary"];
          before = [];
          data = ''
            run ${lib.getExe guidelinesImport} ${lib.escapeShellArgs accountDirs}
          '';
        };
      };

      preferences.agents.claudeHooks = {
        SessionStart = [
          "${lib.getExe agentNet} hook session-start"
          "${lib.getExe agentGit} hook session-start"
        ];
        UserPromptSubmit = ["${lib.getExe agentNet} hook prompt"];
        Stop = ["${lib.getExe agentGit} hook stop"];
      };
    };
  };

  perSystem = {pkgs, ...}: {
    checks.agent-env = pkgs.runCommand "agent-env-check" {nativeBuildInputs = [pkgs.python3 pkgs.bash pkgs.coreutils pkgs.git];} ''
      cp -r ${./agent-env} agent-env
      export HOME=$TMPDIR
      python3 -m unittest discover -s agent-env/tests -v
      touch $out
    '';
  };
}
