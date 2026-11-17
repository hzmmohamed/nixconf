# Thin client for remote coding agents (design: docs/plans/2026-11-17-agentic-workspace-design.md).
# Import together with `agent-common` (same Claude Code / OpenCode / MCP /
# herdr config, so light local work also works) and `agent-t3code` (desktop
# entry for the T3 Code UI on preferences.agents.target).
{inputs, ...}: {
  flake.nixosModules.agent-client = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.agents;
    user = config.preferences.user.name;
    llm = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
  in {
    options.preferences.agents.zed.enable = lib.mkEnableOption "Zed for reading/editing (ACP agents)";

    config = {
      preferences.agents.role = "client";

      home-manager.users.${user} = lib.mkMerge [
        (lib.mkIf (cfg.target != null) {
          # Attach to the target's herdr server over SSH (uses ~/.ssh/config).
          xdg.desktopEntries.herdr-remote = {
            name = "herdr (${cfg.target})";
            genericName = "Agent workspace";
            exec = "${lib.getExe llm.herdr} --remote ${cfg.target}";
            terminal = true;
            icon = "utilities-terminal";
            categories = ["Development"];
          };
        })

        (lib.mkIf cfg.zed.enable {
          programs.zed-editor.enable = true;
          # ACP adapter for Claude Code (Zed's external agent support); wire it
          # up in Zed's agent_servers settings if Zed's built-in one is not used.
          home.packages = [llm.claude-agent-acp];
        })
      ];
    };
  };
}
