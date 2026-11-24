{inputs, ...}: {
  flake.nixosModules.firefox = {
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
  in {
    programs.firefox.enable = true;
    programs.firefox.policies = {
      # Microsoft 365 web apps (Teams, Outlook) renew tokens in a hidden
      # login.microsoftonline.com iframe. Total Cookie Protection gives that
      # iframe an empty partitioned jar, so once the 24 h SPA refresh token
      # expires Teams shows "We need you to sign in again". Allowing the login
      # origin's cookies lets the iframe see the real session.
      Cookies.Allow = [
        "https://login.microsoftonline.com"
      ];
      DisableTelemetry = true;
      DisableFirefoxStudies = true;
      HttpsOnlyMode = "enabled"; # user can still click through per site
      # System DNS already goes out over DoH (MagicDNS, features/dns.nix) and
      # `captive` relies on Firefox using it; keep Firefox's own TRR off.
      DNSOverHTTPS.Enabled = false;
      # Safe Browsing stays on (Firefox default): ungoogled-chromium has none.
    };

    home-manager.users.${user}.programs.firefox = {
      enable = true;
      # Keep legacy profile path (~/.mozilla/firefox) until stateVersion >= 26.05.
      configPath = ".mozilla/firefox";
      profiles.${user} = {
        extensions.packages = with inputs.firefox-addons.packages.${pkgs.stdenv.hostPlatform.system}; [
          keepassxc-browser # vault (features/vault.nix); HM installs the native host
          multi-account-containers
          tree-style-tab
          ublock-origin # malvertising/fake download buttons: the main web threat
          zotero-connector
        ];
        # Firefox's default four (ids kept, so existing container cookies
        # survive) + Facebook Container's jar.
        containersForce = true;
        containers = {
          Personal = {
            id = 1;
            icon = "fingerprint";
            color = "blue";
          };
          Work = {
            id = 2;
            icon = "briefcase";
            color = "orange";
          };
          Banking = {
            id = 3;
            icon = "dollar";
            color = "green";
          };
          Shopping = {
            id = 4;
            icon = "cart";
            color = "pink";
          };
          Facebook = {
            id = 6;
            icon = "fence";
            color = "toolbar";
          };
        };
      };
    };

    persistance.data.directories = [
      ".mozilla"
    ];

    persistance.cache.directories = [
      ".cache/mozilla"
    ];

    preferences.keymap = {
      "SUPER + d"."f".package = pkgs.firefox;
    };
  };
}
