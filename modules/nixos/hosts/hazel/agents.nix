# Agentic workspace: hazel is the client; heavy work runs on butternut.
{self, ...}: {
  flake.nixosModules.hostHazel = {pkgs, ...}: {
    imports = [
      self.nixosModules.agent-common
      self.nixosModules.agent-client
      self.nixosModules.agent-t3code
      self.nixosModules.agent-opencode
    ];

    preferences.agents = {
      target = "butternut";
      tailnetDomain = "tail1a9f7c.ts.net";
      zed.enable = true;
    };

    # `cloud-box up|down|status`: the on-demand EC2 agent host (fern), for
    # data work next to S3 (docs/plans/2026-11-17-aws-agent-host.md).
    environment.systemPackages = [self.packages.${pkgs.stdenv.hostPlatform.system}.cloud-box];
  };
}
