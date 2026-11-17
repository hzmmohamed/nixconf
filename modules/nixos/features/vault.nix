# Local-first password vault: a KeePassXC database synced by Syncthing
# between the user's devices (docs/plans/2026-11-17-secrets-design.md).
#
# Phase 1 (this module): the `vault` Syncthing folder (~/Vault) on every host
# that imports it, plus KeePassXC with a managed config on desktop hosts.
# KeePassXC is NOT the Secret Service provider yet (FdoSecrets off):
# gnome-keyring keeps serving email OAuth tokens, Chromium and VSCodium.
#
# Owns its infrastructure: the Syncthing folder, extra devices (phone, an
# optional untrusted cloud peer) and, when such an untrusted peer exists, the
# sops secret holding the folder's encryption password.
#
# Requires: syncthing (and sops, for an untrusted peer) imported on the host.
{...}: {
  flake.nixosModules.vault = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.vault;
    user = config.preferences.user.name;
    group = config.users.users.${user}.group;
    home = config.users.users.${user}.home;
    gui = config.preferences.desktop.enable;

    # Device registry: hosts registry (modules/hosts-registry.nix, via
    # features/syncthing.nix) plus cfg.extraDevices.
    registry = config.services.syncthing.settings.devices;
    knownPeers = lib.filter (d: registry ? ${d}) cfg.peers;
    missingPeers = lib.filter (d: !(registry ? ${d})) cfg.peers;

    untrusted = lib.filterAttrs (_: d: d.untrusted) cfg.extraDevices;
    trusted = lib.filterAttrs (_: d: !d.untrusted) cfg.extraDevices;
    encryptionPasswordFile = config.sops.secrets."vault/encryption-password".path;

    # Super+p: focus the KeePassXC window, or (re)open it from the tray.
    # A second `keepassxc` hands over to the running instance, which shows
    # its main window; sway focuses newly mapped windows.
    vaultOpen = pkgs.writeShellApplication {
      name = "vault-open";
      runtimeInputs = [pkgs.sway cfg.package];
      text = ''
        swaymsg -q '[app_id="org.keepassxc.KeePassXC"] focus' 2>/dev/null || exec keepassxc
      '';
    };

    vaultAutostart = pkgs.writeShellApplication {
      name = "vault-autostart";
      runtimeInputs = [cfg.package];
      text = "exec keepassxc --minimized";
    };
  in {
    options.preferences.vault = {
      enable = lib.mkEnableOption "the KeePassXC vault synced by Syncthing" // {default = true;};

      path = lib.mkOption {
        type = lib.types.str;
        default = "${home}/Vault";
        defaultText = lib.literalExpression ''"''${home}/Vault"'';
        description = ''
          Synced folder holding the .kdbx database(s). Never put the key
          file in here: it would travel with the database.
        '';
      };

      peers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["butternut" "hazel" "maple"];
        description = ''
          Hosts with a `syncthingId` in modules/hosts-registry.nix
          that share the vault folder. Names without a registered device ID
          are skipped with a warning.
        '';
      };

      extraDevices = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            id = lib.mkOption {
              type = lib.types.str;
              description = "Syncthing device ID (Syncthing app: Actions → Show ID).";
            };
            untrusted = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Untrusted (encrypted) peer, e.g. an off-site cloud node: it
                stores only ciphertext and can never read the vault. Needs
                `vault/encryption-password` in secrets/shared/vault.yaml.
              '';
            };
          };
        });
        default = {};
        description = ''
          Vault peers that are not NixOS hosts in this flake (the Android
          phone, an optional cloud backup node). Set them once in this module
          (see the TODO below) so every peer agrees on the device list.
        '';
      };

      keepVersions = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Keep old versions of the vault (staggered Syncthing versioning,
          one year). Enable on the always-on host (maple).
        '';
      };

      package = lib.mkPackageOption pkgs "keepassxc" {};

      autoLockSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 900;
        description = "Lock the database after this many seconds without KeePassXC activity.";
      };

      clipboardClearSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Clear copied passwords from the clipboard after this many seconds.";
      };

      autostart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Start KeePassXC minimized to the tray with the session (desktop hosts).";
      };

      sshAgent = lib.mkEnableOption ''
        KeePassXC's SSH agent integration (adds keys stored in the vault to
        the running agent, gpg-agent here, while the database is unlocked)
      '';
    };

    config = lib.mkIf cfg.enable (lib.mkMerge [
      {
        # The Android phone (Syncthing-Fork + KeePassDX). A cloud backup node,
        # if set up later, goes here too (untrusted = true).
        preferences.vault.extraDevices = lib.mkDefault {
          phone = {id = "E7AO72L-5POWRSR-E6SIMFL-P4GEQV4-7UYVK6R-BSXUVZC-JMCSOLJ-IXEF3AA";};
          # cloud = {
          #   id = "XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX";
          #   untrusted = true;
          # };
        };

        warnings =
          map (d: "preferences.vault: peer `${d}` has no syncthingId in modules/hosts-registry.nix; it does not get the vault.")
          missingPeers;

        sops.secrets."vault/encryption-password" = lib.mkIf (untrusted != {}) {
          sopsFile = ../../.. + "/secrets/shared/vault.yaml";
          owner = user;
          inherit group;
          mode = "0400";
          restartUnits = ["syncthing-init.service"];
        };

        services.syncthing.settings = {
          devices =
            lib.mapAttrs (_: d: {inherit (d) id;}) trusted
            // lib.mapAttrs (_: d: {
              inherit (d) id;
              untrusted = true;
            })
            untrusted;

          folders.vault = {
            label = "Vault";
            inherit (cfg) path;
            ignorePerms = false;
            # Push KeePassXC saves to the other peers quickly (default 10 s),
            # which keeps the window for conflicting edits small.
            fsWatcherDelayS = 1;
            devices =
              knownPeers
              ++ lib.attrNames trusted
              ++ lib.mapAttrsToList (name: _: {
                inherit name encryptionPasswordFile;
              })
              untrusted;
            versioning = lib.mkIf cfg.keepVersions {
              type = "staggered";
              params = {
                cleanInterval = "3600";
                maxAge = toString (365 * 24 * 3600);
              };
            };
          };
        };

        # Private before Syncthing first creates it.
        systemd.tmpfiles.rules = ["d ${cfg.path} 0700 ${user} ${group} -"];

        persistance.data.directories = [(lib.removePrefix "${home}/" cfg.path)];
      }

      (lib.mkIf gui {
        preferences.autostart = lib.mkIf cfg.autostart [vaultAutostart];

        home-manager.users.${user} = {
          programs.keepassxc = {
            enable = true;
            inherit (cfg) package;
            # Written to ~/.config/keepassxc/keepassxc.ini (read-only store
            # link: KeePassXC warns when it tries to save settings changed in
            # the GUI). Window state, recent databases and key files live in
            # ~/.cache/keepassxc and stay writable.
            # Keys: https://github.com/keepassxreboot/keepassxc/blob/develop/src/core/Config.cpp
            settings = {
              General = {
                SingleInstance = true;
                RememberLastDatabases = true;
                RememberLastKeyFiles = true;
                OpenPreviousDatabasesOnStartup = true;
                AutoSaveAfterEveryChange = true;
                # Reload (and merge unsaved edits) when Syncthing replaces the file.
                AutoReloadOnChange = true;
                UseAtomicSaves = true;
                # A .old.kdbx next to the database would be synced too;
                # history lives in Syncthing versioning on maple instead.
                BackupBeforeSave = false;
              };
              GUI = {
                ApplicationTheme = "auto";
                CheckForUpdates = false;
                CompactMode = true;
                ShowTrayIcon = true;
                TrayIconAppearance = "monochrome-light";
                MinimizeToTray = true;
                MinimizeOnClose = true;
                MinimizeOnStartup = true;
              };
              Security = {
                LockDatabaseIdle = true;
                LockDatabaseIdleSeconds = cfg.autoLockSeconds;
                LockDatabaseScreenLock = true;
                ClearClipboard = true;
                ClearClipboardTimeout = cfg.clipboardClearSeconds;
                IconDownloadFallback = false;
              };
              # Browser extension (KeePassXC-Browser); home-manager installs
              # the native messaging manifest, so KeePassXC must not rewrite it.
              Browser = {
                Enabled = true;
                UpdateBinaryPath = false;
              };
              SSHAgent.Enabled = cfg.sshAgent;
              # Phase 2: KeePassXC as org.freedesktop.secrets, replacing
              # gnome-keyring. Off until the migration in the design doc.
              FdoSecrets.Enabled = false;
            };
          };

          # Alongside the Bitwarden extension during the migration period.
          programs.chromium.extensions = [
            {id = "oboonakemofpalcgghocfoadofidjkkk";} # KeePassXC-Browser
          ];

          home.packages = [vaultOpen];

          wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault {
            "Mod4+p" = "exec ${lib.getExe vaultOpen}";
          };
        };
      })
    ]);
  };
}
