{...}: {
  flake.nixosModules.email = {config, ...}: let
    user = config.preferences.user.name;
  in {
    # gnome-keyring as secret-service provider for OAuth2 tokens
    services.gnome.gnome-keyring.enable = true;

    # PAM: auto-unlock keyring on login, re-unlock after swaylock
    security.pam.services.greetd.enableGnomeKeyring = true;
    security.pam.services.swaylock.enableGnomeKeyring = true;

    home-manager.users.${user} = {
      programs.thunderbird = {
        enable = true;

        # Follow system dark/light preference (set by darkman via GTK/dconf)
        settings = {
          "browser.theme.content-theme" = 2; # 2 = follow system
          "browser.theme.toolbar-theme" = 2;
          "layout.css.prefers-color-scheme.content-override" = 2; # 2 = follow system
          "browser.in-content.dark-mode" = true; # allow dark mode in content
        };

        profiles.hfahmi = {
          isDefault = true;
          search.default = "ddg";
        };
      };

      accounts.email.accounts = {
        personal = {
          address = "hzmmohamed@gmail.com";
          flavor = "gmail.com";
          primary = true;
          realName = "Hazem Fahmi";
          signature = {
            delimiter = "--";
            text = ''
              Hazem Fahmi
            '';
            showSignature = "append";
          };
          thunderbird = {
            enable = true;
            profiles = ["hfahmi"];
            settings = id: {
              # OAuth2 authentication (method 10)
              "mail.server.server_${id}.authMethod" = 10;
              "mail.smtpserver.smtp_${id}.authMethod" = 10;
              "mail.server.server_${id}.autosync_max_age_days" = 30;
            };
          };
        };

        work = {
          address = "h.fahmi@transportforcairo.com";
          flavor = "outlook.office365.com";
          realName = "Hazem Fahmi";
          signature = {
            delimiter = "--";
            text = ''
              Hazem Fahmi
              Senior Research Software Engineer
            '';
            showSignature = "append";
          };
          thunderbird = {
            enable = true;
            profiles = ["hfahmi"];
            settings = id: {
              # OAuth2 authentication (method 10)
              "mail.server.server_${id}.authMethod" = 10;
              "mail.smtpserver.smtp_${id}.authMethod" = 10;
            };
          };
        };
      };
    };
  };
}
