# Agentic workspace: butternut is a compute target (agent-host).
{self, ...}: {
  flake.nixosModules.hostButternut = {
    imports = [
      self.nixosModules.agent-common
      self.nixosModules.agent-host
      self.nixosModules.agent-t3code
    ];
  };
}
