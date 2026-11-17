# Agentic workspace: butternut is a compute target (agent-host).
{self, ...}: {
  flake.nixosModules.hostButternut = {
    config,
    pkgs,
    ...
  }: let
    home = config.users.users.${config.preferences.user.name}.home;
  in {
    imports = [
      self.nixosModules.agent-common
      self.nixosModules.agent-host
      self.nixosModules.agent-t3code
      self.nixosModules.agent-opencode
      self.nixosModules.secretspec
    ];

    # AWS Identity Center profiles (tfc-admin/-operator/-cloudbox) in
    # ~/.aws/config; `aws-login` (docs/plans/2026-11-17-aws-sso-runbook.md).
    # Agent host: an SSO token in ~/.aws/sso/cache can be exchanged for every
    # permission set of the user (Admin too), so agents here can reach it
    # while it is valid. `aws sso logout` after admin work.
    preferences.aws.sso.enable = true;

    preferences.agents = {
      tailnetDomain = "tail1a9f7c.ts.net";
      # Registered with T3 Code on start (skipped when not checked out).
      projects = [
        "${home}/work/tfc/repos/routelab-monorepo"
        "${home}/work/tfc/repos/d_abm"
      ];
    };

    # `cloud-box up|down|status`: the on-demand EC2 agent host (fern).
    environment.systemPackages = [self.packages.${pkgs.stdenv.hostPlatform.system}.cloud-box];
  };
}
