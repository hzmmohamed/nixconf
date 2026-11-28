# agent-net: is the current link metered, unmetered or offline? (JSON with
# --json). A flake package so other flakes' modules can take it: agent-env
# (agent-common) installs it for agents, attn's daemon shells out to it for
# its metered upload policy (features/attn.nix). `--suffix PATH`, as
# agent-env's other tools: its deps never shadow the caller's PATH.
{...}: {
  perSystem = {
    lib,
    pkgs,
    ...
  }: {
    packages.agent-net =
      pkgs.runCommand "agent-net" {
        nativeBuildInputs = [pkgs.makeWrapper];
        meta.mainProgram = "agent-net";
      } ''
        makeWrapper ${pkgs.python3}/bin/python3 $out/bin/agent-net \
          --add-flags ${../nixos/features/agent-env/agent_net.py} \
          --suffix PATH : ${lib.makeBinPath [pkgs.networkmanager pkgs.iproute2]}
      '';
  };
}
