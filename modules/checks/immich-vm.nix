# immich-vm: a NixOS VM running features/immich.nix with no Tailscale. Proves
# nixpkgs-unstable's Immich 3.x (module + package) comes up on 26.05's
# Postgres/VectorChord (DB migrations run on first start) and listens on
# loopback only. Builds Immich + ML + Postgres: run it on butternut.
#   nix build --no-link -L .#checks.x86_64-linux.immich-vm
{self, ...}: {
  perSystem = {pkgs, ...}: {
    checks.immich-vm = pkgs.testers.runNixOSTest {
      name = "immich-vm";
      nodes.machine = {pkgs, ...}: {
        imports = [self.nixosModules.immich];
        virtualisation = {
          memorySize = 4096;
          diskSize = 8192;
        };
        environment.systemPackages = [pkgs.curl];
      };
      testScript = ''
        import json

        machine.wait_for_unit("immich-server.service")
        machine.wait_for_open_port(2283)
        v = json.loads(machine.succeed("curl -sf http://127.0.0.1:2283/api/server/version"))
        assert v["major"] == 3, v
        machine.succeed("curl -sf http://127.0.0.1:2283/api/server/ping | grep -q pong")
        machine.fail("ss -ltn | grep -q '0.0.0.0:2283'")  # loopback only
      '';
    };
  };
}
