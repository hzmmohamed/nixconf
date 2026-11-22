# Agentic workspace: butternut is a compute target (agent-host) and, with a
# monitor attached, also runs the T3 desktop app against its own server.
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
      self.nixosModules.github
      self.nixosModules.agent-opencode
      self.nixosModules.secretspec
    ];

    # AWS Identity Center profiles (tfc-admin/-operator/-cloudbox) in
    # ~/.aws/config; `aws-login` (docs/plans/2026-11-17-aws-sso-runbook.md).
    # Agent host: an SSO token in ~/.aws/sso/cache can be exchanged for every
    # permission set of the user (Admin too), so agents here can reach it
    # while it is valid. `aws sso logout` after admin work.
    preferences.aws.sso.enable = true;

    # Reached over SSH without a session (keyring locked): gh keeps its token
    # in ~/.config/gh/hosts.yml (features/github.nix).
    preferences.github.tokenInFile = true;

    # Agents here also run headless (no login → gnome-keyring stays locked),
    # so project dev secrets come from sops files like on fern:
    # preferences.secretspec.fileSecrets."<project>/<profile>/<KEY>" =
    #   {sopsFile = ../../../../secrets/butternut/secretspec.yaml; key = "…";};
    # Human-only profiles keep the keyring (`human` alias).
    preferences.secretspec.team = "file:///run/secrets/secretspec";

    preferences.agents = {
      tailnetDomain = "tail1a9f7c.ts.net";
      # Registered with T3 Code on start (skipped when not checked out).
      projects = [
        "${home}/work/tfc/repos/routelab-monorepo"
        "${home}/work/tfc/repos/d_abm"
        "${home}/nixconf"
      ];

      # routelab's Android emulator as a T3 device (KVM, headless; T3 boots
      # the AVDs from the repo's .android/avd). The SDK comes from routelab's
      # own mobile shell: `rl-dev-mobile -c t3-android-sdk` once
      # (docs/plans/2026-11-17-t3-devices-routelab.md).
      t3code.devices.android = let
        routelab = "${home}/work/tfc/repos/routelab-monorepo";
      in {
        enable = true;
        avdHome = "${routelab}/.android/avd";
        userHome = "${routelab}/.android";
      };
    };

    # `cloud-box up|down|status`: the on-demand EC2 agent host (fern).
    environment.systemPackages = [self.packages.${pkgs.stdenv.hostPlatform.system}.cloud-box];
  };
}
