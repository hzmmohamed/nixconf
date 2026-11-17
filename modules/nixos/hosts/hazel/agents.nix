# Agentic workspace: hazel is the client; heavy work runs on butternut.
{self, ...}: {
  flake.nixosModules.hostHazel = {
    imports = [
      self.nixosModules.agent-common
      self.nixosModules.agent-client
      self.nixosModules.agent-t3code
    ];

    preferences.agents = {
      target = "butternut";
      zed.enable = true;
    };
  };
}
