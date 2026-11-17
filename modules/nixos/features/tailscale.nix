{self, ...}: {
  # Tailscale on every host. ACL/grants draft: docs/tailscale-policy.hujson
  # (applied by hand in the admin console).
  #
  # Login: by default the shared reusable auth key (secrets/shared/tailscale.yaml,
  # key `tailscale_authkey`; expires after <= 90 days). Headless servers can
  # instead use an OAuth client secret (`preferences.tailscale.oauth.enable`):
  # it never expires and mints a pre-authorized, TAGGED node key on login, so
  # the node never needs re-auth and has no key expiry.
  #   Admin console → Settings → OAuth clients → scope "Auth Keys" (write),
  #   tags tag:server tag:gpu tag:cloud tag:agent-host →
  #   secrets/shared/tailscale-oauth.yaml, key `tailscale_oauth` =
  #   tskey-client-… (`bash scripts/fern/tailscale.sh store` writes it).
  #   Keep that client auth-keys only: every OAuth host can read it.
  #   Tags come from the hosts registry.
  # Only used when the node needs login (autoconnect runs `tailscale up` in
  # NeedsLogin/Stopped). To move an existing node: `doas tailscale logout`,
  # then `doas systemctl restart tailscaled-autoconnect`.
  flake.nixosModules.tailscale = {
    config,
    lib,
    ...
  }: let
    cfg = config.preferences.tailscale;
    user = config.preferences.user.name;
    oauthFile = ../../.. + "/secrets/shared/tailscale-oauth.yaml";
    oauthOn = cfg.oauth.enable && builtins.pathExists oauthFile && cfg.tags != [];
  in {
    options.preferences.tailscale = {
      tags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = (self.hosts.${config.networking.hostName} or {}).tags or [];
        defaultText = lib.literalExpression "self.hosts.<host>.tags";
        description = "ACL tags advertised when logging in with the OAuth client.";
      };

      oauth.enable = lib.mkEnableOption ''
        login with the OAuth client secret (secrets/shared/tailscale-oauth.yaml,
        key `tailscale_oauth`) as a tagged node. Skipped with a warning while the
        file is missing'';
    };

    config = {
      warnings =
        lib.optional (cfg.oauth.enable && !builtins.pathExists oauthFile)
        "preferences.tailscale.oauth.enable: secrets/shared/tailscale-oauth.yaml (key tailscale_oauth) is missing or not git-added; using the shared auth key."
        ++ lib.optional (cfg.oauth.enable && cfg.tags == [])
        "preferences.tailscale.oauth.enable: no tags for ${config.networking.hostName} (hosts registry); OAuth logins require tags, using the shared auth key.";

      # Tray icon only on hosts with a desktop.
      home-manager.users.${user} = lib.mkIf config.preferences.desktop.enable {
        services.tailscale-systray.enable = true;
      };

      services.tailscale = {
        enable = true;
        extraUpFlags =
          ["--ssh"]
          ++ lib.optional oauthOn "--advertise-tags=${lib.concatStringsSep "," cfg.tags}";
        authKeyFile =
          if oauthOn
          then config.sops.secrets."tailscale_oauth".path
          else config.sops.secrets."tailscale_authkey".path;
        authKeyParameters = lib.mkIf oauthOn {
          preauthorized = true;
          ephemeral = false;
        };
        # The primary user may run `tailscale set/serve/file` without root:
        # `captive` (dns.nix), `tailscale serve` (agents), Taildrop.
        extraSetFlags = ["--operator=${user}"];
      };

      sops.secrets =
        {
          "tailscale_authkey".sopsFile = ../../../secrets/shared/tailscale.yaml;
        }
        // lib.optionalAttrs oauthOn {
          "tailscale_oauth".sopsFile = oauthFile;
        };

      networking.firewall = {
        trustedInterfaces = [config.services.tailscale.interfaceName];
        checkReversePath = "loose";
        allowedUDPPorts = [config.services.tailscale.port];
        # No global TCP 22: sshd listens on 7654 (openssh.nix) and Tailscale SSH
        # arrives over tailscale0, which is trusted above.
      };
    };
  };
}
