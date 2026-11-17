# Agentic workspace: hazel is the client; heavy work runs on butternut.
{self, ...}: {
  flake.nixosModules.hostHazel = {
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
  };
}
