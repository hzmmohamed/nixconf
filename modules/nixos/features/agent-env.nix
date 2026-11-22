# Network-aware agent tooling: `agent-net` reports whether the current
# connection is metered (so later tasks — nx's download budget,
# agent-devshell — can behave on a phone hotspot). Contributes to
# `flake.nixosModules.agent-common` (see agent-common.nix for the rest of
# that module; files are merged the same way modules/nixos/hosts/butternut/*.nix
# all contribute to `hostButternut`).
{...}: {
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
    mkTool = name: script: deps:
      pkgs.runCommand name {
        nativeBuildInputs = [pkgs.makeWrapper];
        meta.mainProgram = name;
      } ''
        makeWrapper ${pkgs.python3}/bin/python3 $out/bin/${name} \
          --add-flags ${script} \
          --suffix PATH : ${lib.makeBinPath deps}
      '';

    agentNet = mkTool "agent-net" ./agent-env/agent_net.py [pkgs.networkmanager pkgs.iproute2];
    # nx: store-first tool runner. nix-index supplies nix-locate (attribute
    # lookup when a bare prog name doesn't match its own nixpkgs attribute);
    # agentNet is its own metered/unmetered/offline source.
    nx = mkTool "nx" ./agent-env/nx.py [pkgs.nix pkgs.nix-index agentNet];
    # agent-devshell: wraps a provider binary so it starts inside the
    # project's direnv dev shell when one is cached and allowed (T3 Code's
    # Claude/OpenCode instances point at claude-devshell/opencode-devshell,
    # below). Never fails closed: it always execs the binary it's given.
    agentDevshell = mkTool "agent-devshell" ./agent-env/agent_devshell.py [pkgs.direnv pkgs.git pkgs.systemd agentNet];

    userBin = "/etc/profiles/per-user/${user}/bin";
    claudeDevshell = pkgs.writeShellScriptBin "claude-devshell" ''
      exec ${lib.getExe agentDevshell} ${userBin}/claude "$@"
    '';
    opencodeDevshell = pkgs.writeShellScriptBin "opencode-devshell" ''
      exec ${lib.getExe agentDevshell} ${userBin}/opencode "$@"
    '';
  in {
    home-manager.users.${user}.home.packages = [agentNet nx agentDevshell claudeDevshell opencodeDevshell];

    preferences.agents.claudeHooks = {
      SessionStart = ["${lib.getExe agentNet} hook session-start"];
      UserPromptSubmit = ["${lib.getExe agentNet} hook prompt"];
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
