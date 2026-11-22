# Agentic workspace: hazel is a full T3 environment of its own (projects and
# threads run here when alone) and the place the user sits: desktop app,
# herdr --remote, Zed. Heavy/GPU threads go to butternut, data threads to
# fern, through the desktop app's host picker or `t3-link` + delegate_task.
{self, ...}: {
  flake.nixosModules.hostHazel = {
    config,
    pkgs,
    ...
  }: let
    home = config.users.users.${config.preferences.user.name}.home;
  in {
    imports = [
      self.nixosModules.agent-common
      self.nixosModules.agent-client
      self.nixosModules.agent-t3code
      self.nixosModules.github
      self.nixosModules.agent-opencode
      self.nixosModules.secretspec
    ];

    # AWS Identity Center profiles (tfc-admin/-operator/-cloudbox) in
    # ~/.aws/config; `aws-login` (docs/plans/2026-11-17-aws-sso-runbook.md).
    # The aws feature itself is imported in configuration.nix.
    preferences.aws.sso.enable = true;

    preferences.agents = {
      target = "butternut";
      tailnetDomain = "tail1a9f7c.ts.net";
      zed.enable = true;
      # Registered with the local T3 server (skipped when not checked out).
      projects = [
        "${home}/work/tfc/repos/routelab-monorepo"
        "${home}/work/tfc/repos/d_abm"
        "${home}/nixconf"
      ];

      t3code = {
        # Own server, started with the graphical session (no lingering):
        # nothing runs before login on the laptop.
        server.enable = true;
        # Battery: no background git fetches, provider health every 15 min,
        # background work paused on battery/low power. Unlocked default.
        policyExtraSettings = {
          "backgroundActivity.profile" = {
            value = "battery-saver";
            locked = false;
          };
          # Free the speech model's RAM sooner on battery.
          speechModelUnloadTimeout = {
            value = "min_5";
            locked = false;
          };
        };
      };
    };

    # `cloud-box up|down|status`: the on-demand EC2 agent host (fern), for
    # data work next to S3 (docs/plans/2026-11-17-aws-agent-host.md).
    environment.systemPackages = [self.packages.${pkgs.stdenv.hostPlatform.system}.cloud-box];
  };
}
