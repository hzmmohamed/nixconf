# immich-vm: a NixOS VM running features/immich.nix with no Tailscale. Proves
# nixpkgs-unstable's Immich 3.x (module + package) comes up on 26.05's
# Postgres/VectorChord (DB migrations run on first start), listens on
# loopback only, applies the declarative settings (read back over the API),
# has no serve unit without Tailscale, and survives a server restart. Builds Immich + ML + Postgres: run it on butternut.
#   nix build --no-link -L .#checks.x86_64-linux.immich-vm
#
# immich-butternut-config: eval-only, butternut's pilot wiring (Immich 3.x,
# serve on 8444, externalDomain, serve unit). Fails at eval, naming the
# condition.
{
  lib,
  self,
  ...
}: {
  perSystem = {pkgs, ...}: {
    checks.immich-butternut-config = let
      c = self.nixosConfigurations.butternut.config;
      url = "https://butternut.${self.tailnet.domain}:8444";
    in
      assert lib.assertMsg c.services.immich.enable "butternut: services.immich.enable is not true";
      assert lib.assertMsg (lib.versions.major c.services.immich.package.version == "3")
      "butternut: Immich is ${c.services.immich.package.version}, not 3.x";
      assert lib.assertMsg (c.preferences.immich.tailscaleServePort == 8444)
      "butternut: preferences.immich.tailscaleServePort is not 8444";
      assert lib.assertMsg (c.services.immich.settings.server.externalDomain == url)
      "butternut: server.externalDomain is not ${url}";
      assert lib.assertMsg (c.systemd.services ? immich-tailscale-serve)
      "butternut: no immich-tailscale-serve unit";
        pkgs.runCommand "immich-butternut-config" {} "echo ok > $out";

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

        # Settings file applied: Immich only warns on unknown keys, so read the
        # effective config back over the API (admin token needed).
        api = "http://127.0.0.1:2283/api"
        creds = '{"email":"admin@example.com","password":"test-password","name":"Admin"}'
        machine.succeed(f"curl -sf -H 'Content-Type: application/json' -d '{creds}' {api}/auth/admin-sign-up")
        tok = json.loads(machine.succeed(
            f"curl -sf -H 'Content-Type: application/json' "
            f"-d '{{\"email\":\"admin@example.com\",\"password\":\"test-password\"}}' {api}/auth/login"
        ))["accessToken"]
        # /admin/config replaces /system-config (deprecated in 3.2); same DTO.
        c = json.loads(machine.succeed(f"curl -sf -H 'Authorization: Bearer {tok}' {api}/admin/config"))
        assert c["storageTemplate"]["enabled"] is True, c["storageTemplate"]
        assert c["storageTemplate"]["template"] == "{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}", c["storageTemplate"]
        assert c["backup"]["database"]["enabled"] is True, c["backup"]
        assert c["backup"]["database"]["cronExpression"] == "0 02 * * *", c["backup"]
        assert c["backup"]["database"]["keepLastAmount"] == 14, c["backup"]
        assert c["newVersionCheck"]["enabled"] is False, c["newVersionCheck"]
        assert c["server"]["externalDomain"] == "https://machine.${self.tailnet.domain}", c["server"]
        assert c["machineLearning"]["urls"] == ["http://localhost:3003"], c["machineLearning"]["urls"]
        assert c["map"]["lightStyle"] == "https://tiles.openfreemap.org/styles/liberty", c["map"]
        assert c["map"]["darkStyle"] == "https://tiles.openfreemap.org/styles/dark", c["map"]

        # No Tailscale on this node: no serve unit.
        machine.fail("systemctl cat immich-tailscale-serve.service")

        # Comes back after a restart.
        machine.succeed("systemctl restart immich-server.service")
        machine.wait_for_open_port(2283)
        machine.succeed("curl -sf http://127.0.0.1:2283/api/server/ping | grep -q pong")
      '';
    };
  };
}
