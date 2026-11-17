{...}: {
  # System-level Wi-Fi profiles (NetworkManager ensureProfiles, written to
  # /run/NetworkManager/system-connections): available at boot, before any
  # login, with no user secret agent — needed for headless butternut.
  #
  #   profile  priority  trusted*  secret (sops, env-file format)
  #   home     30        yes       secrets/shared/wifi.yaml          key wifi_env:
  #                                  WIFI_HOME_PSK=...
  #   office   20        no        secrets/shared/wifi-office.yaml   key wifi_office_env:
  #                                  WIFI_OFFICE_SSID=...  WIFI_OFFICE_PSK=...
  #   hotspot  10        yes       secrets/shared/wifi-hotspot.yaml  key wifi_hotspot_env:
  #                                  WIFI_HOTSPOT_SSID=...  WIFI_HOTSPOT_PSK=...
  #   (* trusted-networks: LAN service ports open on that connection)
  #
  # NM picks the highest-priority VISIBLE known network, so at home/office the
  # phone's mobile data is never used just because the hotspot is on. office
  # and hotspot are opt-in per host (`preferences.wifi.<p>.enable`) and also
  # need their secret file: enabled without it → a warning, profile skipped
  # (eval keeps passing). Create with `sops secrets/shared/wifi-hotspot.yaml`,
  # then `git add` it.
  #
  # The module keeps its historical name; it now owns every Wi-Fi profile.
  flake.nixosModules.wifi-home = {
    config,
    lib,
    ...
  }: let
    cfg = config.preferences.wifi;
    secretsDir = ../../../secrets/shared;

    optional = name: file: let
      c = cfg.${name};
      present = builtins.pathExists file;
    in {
      inherit c file;
      on = c.enable && present;
      missing = c.enable && !present;
    };
    office = optional "office" (secretsDir + "/wifi-office.yaml");
    hotspot = optional "hotspot" (secretsDir + "/wifi-hotspot.yaml");

    keyMgmtOpt = lib.mkOption {
      type = lib.types.enum ["wpa-psk" "sae"];
      default = "wpa-psk";
      description = "`wpa-psk` (WPA2 / WPA2+WPA3 transition) or `sae` (WPA3-only).";
    };

    wifiProfile = {
      id,
      ssid,
      psk,
      priority,
      autoconnect ? true,
      keyMgmt ? "wpa-psk",
      extra ? {},
    }:
      lib.recursiveUpdate {
        connection = {
          inherit id autoconnect;
          type = "wifi";
          autoconnect-priority = priority;
        };
        wifi = {
          inherit ssid;
          mode = "infrastructure";
        };
        wifi-security = {
          key-mgmt = keyMgmt;
          inherit psk;
        };
      }
      extra;
  in {
    options.preferences.wifi = {
      home.ssid = lib.mkOption {
        type = lib.types.str;
        default = "WE_93CBE9";
        description = "SSID of the home network (PSK: WIFI_HOME_PSK in secrets/shared/wifi.yaml).";
      };

      office = {
        enable = lib.mkEnableOption "the office Wi-Fi profile (secrets/shared/wifi-office.yaml)";
        keyMgmt = keyMgmtOpt;
      };

      hotspot = {
        enable = lib.mkEnableOption "the phone-hotspot Wi-Fi profile (secrets/shared/wifi-hotspot.yaml)";
        autoconnect = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Join the hotspot automatically when no higher-priority network is visible.";
        };
        keyMgmt = keyMgmtOpt;
      };
    };

    config = {
      warnings =
        lib.optional office.missing "preferences.wifi.office.enable: secrets/shared/wifi-office.yaml (key wifi_office_env) is missing or not git-added; office profile skipped."
        ++ lib.optional hotspot.missing "preferences.wifi.hotspot.enable: secrets/shared/wifi-hotspot.yaml (key wifi_hotspot_env) is missing or not git-added; hotspot profile skipped.";

      sops.secrets =
        {
          "wifi_env".sopsFile = secretsDir + "/wifi.yaml";
        }
        // lib.optionalAttrs office.on {"wifi_office_env".sopsFile = office.file;}
        // lib.optionalAttrs hotspot.on {"wifi_hotspot_env".sopsFile = hotspot.file;};

      networking.networkmanager.ensureProfiles = {
        environmentFiles =
          [config.sops.secrets."wifi_env".path]
          ++ lib.optional office.on config.sops.secrets."wifi_office_env".path
          ++ lib.optional hotspot.on config.sops.secrets."wifi_hotspot_env".path;

        profiles =
          {
            home = wifiProfile {
              id = "home";
              inherit (cfg.home) ssid;
              psk = "$WIFI_HOME_PSK";
              priority = 30;
            };
          }
          // lib.optionalAttrs office.on {
            office = wifiProfile {
              id = "office";
              ssid = "$WIFI_OFFICE_SSID";
              psk = "$WIFI_OFFICE_PSK";
              priority = 20;
              inherit (cfg.office) keyMgmt;
            };
          }
          // lib.optionalAttrs hotspot.on {
            hotspot = wifiProfile {
              id = "hotspot";
              ssid = "$WIFI_HOTSPOT_SSID";
              psk = "$WIFI_HOTSPOT_PSK";
              priority = 10;
              inherit (cfg.hotspot) autoconnect keyMgmt;
              extra = {
                # Mobile data: apps that honour it (GNOME, some sync tools) back off.
                connection.metered = 1; # keyfile encoding of "yes"
                # Shows up by name in the phone's hotspot client list: the
                # fallback for finding a headless laptop's IP.
                ipv4.dhcp-send-hostname = 1; # ternary in keyfiles: 1 = yes
              };
            };
          };
      };
    };
  };
}
