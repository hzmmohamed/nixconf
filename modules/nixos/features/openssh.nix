{self, ...}: {
  # OpenSSH server shared by all hosts (port 7654, no root login).
  #
  # Rollout for disabling password logins without a lockout:
  #   1. switch with authorized keys present (default: all of `self.sshKeys`)
  #   2. verify key login to every host: `ssh -p 7654 <host>`
  #   3. set `preferences.ssh.passwordAuthentication = false` and switch
  flake.nixosModules.openssh = {
    config,
    lib,
    ...
  }: let
    cfg = config.preferences.ssh;
  in {
    options.preferences.ssh = {
      passwordAuthentication = lib.mkOption {
        type = lib.types.bool;
        # TODO: flip to false once key login is verified on every host.
        default = true;
        description = ''
          Allow password (and keyboard-interactive/PAM) logins over SSH.
          Only disable after confirming key-based login works.
        '';
      };

      authorizedKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = builtins.attrValues self.sshKeys;
        description = "Public keys allowed to log in as the primary user.";
      };
    };

    config = {
      services.openssh = {
        enable = true;
        ports = [7654];
        # Not on every interface: tailscale0, the cable and trusted Wi-Fi only
        # (trusted-networks). Café Wi-Fi reaches sshd over the tailnet only.
        openFirewall = false;
        settings = {
          PasswordAuthentication = cfg.passwordAuthentication;
          # Keyboard-interactive goes through PAM and would still accept the
          # password, so it must follow PasswordAuthentication.
          KbdInteractiveAuthentication = cfg.passwordAuthentication;
          PermitRootLogin = "no";
        };
      };

      users.users.${config.preferences.user.name}.openssh.authorizedKeys.keys = cfg.authorizedKeys;

      preferences.trustedNetworks.allowedTCPPorts = config.services.openssh.ports;
    };
  };
}
