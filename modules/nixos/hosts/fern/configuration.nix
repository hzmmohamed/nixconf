{
  inputs,
  self,
  ...
}: {
  flake.nixosConfigurations.fern = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.hostFern
    ];
  };

  # fern: on-demand EC2 agent host next to the d_abm data in S3
  # (docs/plans/2026-11-17-aws-agent-host.md). Headless, no desktop. Started
  # with `cloud-box up`, stops itself when idle (cloud-idle-stop). Born from the
  # official NixOS AMI + infra/aws/bootstrap.nix.tftpl, then `just deploy fern`
  # (builds on the box: hosts-registry `buildOnTarget`).
  flake.nixosModules.hostFern = {
    config,
    lib,
    modulesPath,
    pkgs,
    ...
  }: let
    home = config.users.users.${config.preferences.user.name}.home;
    d_abm = "${home}/work/tfc/repos/d_abm";
  in {
    imports = [
      "${modulesPath}/virtualisation/amazon-image.nix"

      self.nixosModules.base
      self.nixosModules.general

      self.nixosModules.sops
      self.nixosModules.openssh
      self.nixosModules.tailscale
      self.nixosModules.doas

      self.nixosModules.zellij
      self.nixosModules.yazi

      # Agentic workspace (compute target)
      self.nixosModules.agent-common
      self.nixosModules.agent-host
      self.nixosModules.agent-t3code
      self.nixosModules.agent-opencode

      # Cloud box specifics
      self.nixosModules.cloud-idle-stop
      self.nixosModules.workspace-bootstrap
    ];

    nixpkgs.hostPlatform = "x86_64-linux";
    networking.hostName = "fern";

    # Must match the AMI the root volume came from: the official x86_64 NixOS
    # AMIs boot legacy BIOS (GRUB on /dev/xvda). Flip only if
    # `test -d /sys/firmware/efi` succeeds on the box before the first deploy.
    ec2.efi = false;

    # amazon-init would re-apply the bootstrap user-data with
    # `nixos-rebuild switch` on every boot, undoing `deploy`.
    virtualisation.amazon-init.enable = false;
    # The instance role has no SSM permissions (least privilege); break-glass
    # is the EC2 serial console.
    services.amazon-ssm-agent.enable = lib.mkForce false;
    # amazon-image allows root with the EC2 key pair; there is none.
    services.openssh.settings.PermitRootLogin = lib.mkForce "no";

    boot.loader.grub.configurationLimit = 5;

    # Per-host sops key: the SSH host key only (converted with ssh-to-age and
    # added to .sops.yaml). The shared master age key never lands here.
    sops.age = {
      keyFile = lib.mkForce null;
      sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    };

    # Tagged node (tag:cloud, tag:agent-host from the hosts registry), never
    # ephemeral: /var/lib/tailscale persists on EBS across stop/start.
    preferences.tailscale.oauth.enable = true;

    preferences.agents = {
      tailnetDomain = self.tailnet.domain;
      projects = [d_abm];
    };

    preferences.workspace.projects.d_abm = {
      path = d_abm;
      # S3-side analysis helpers (they stay on PATH inside direnv shells).
      packages = with pkgs; [s5cmd duckdb awscli2];
    };

    preferences.cloudIdleStop.idleMinutes = 45;

    # The SDKs find the instance role through IMDS; no AWS_PROFILE here.
    environment.variables = {
      AWS_REGION = "eu-central-1";
      AWS_DEFAULT_REGION = "eu-central-1";
    };

    nix = {
      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 14d";
      };
      optimise.automatic = true;
    };

    services.journald.extraConfig = ''
      SystemMaxUse=1G
      MaxRetentionSec=1month
    '';

    time.timeZone = "Africa/Cairo";

    # The AMI it was born from (nixos/25.11.* x86_64).
    system.stateVersion = "25.11";
  };
}
