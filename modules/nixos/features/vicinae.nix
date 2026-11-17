{
  # Vicinae — Raycast-style launcher (apps, file search, calculator, emoji,
  # extensions). Runs as a user daemon bound to the graphical session; the
  # compositor only needs to bind `vicinae toggle`.
  flake.nixosModules.vicinae = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
  in {
    # vicinae's input server injects keystrokes through /dev/uinput for
    # "paste to active window" (emoji picker, snippets). Without it, actions
    # fall back to copying to the clipboard.
    hardware.uinput.enable = true;
    users.users.${user}.extraGroups = ["uinput"];

    home-manager.users.${user} = {config, ...}: let
      home = config.home.homeDirectory;
    in {
      programs.vicinae = {
        enable = true;
        systemd = {
          enable = true;
          target = "graphical-session.target";
        };

        settings = {
          telemetry.system_info = false;
          pop_to_root_on_close = true;
          favicon_service = "none";

          # Built-in catppuccin themes. vicinae follows the portal's
          # org.freedesktop.appearance color-scheme (written by darkman via
          # dconf → xdg-desktop-portal-gtk), so this switches live.
          theme = {
            light.name = "catppuccin-latte";
            dark.name = "catppuccin-mocha";
          };

          # Opaque, no blur/glass.
          launcher_window = {
            opacity = 1.0;
            material = "none";
          };

          favorites = [];
          fallbacks = ["files:search"];

          providers = {
            # Clipboard history (text + images); replaces clipse. Hosts bind
            # a key to `vicinae deeplink vicinae://launch/clipboard/history`.
            # ignorePasswords drops selections offered with the
            # x-kde-passwordManagerHint mime type (password managers,
            # `wl-copy --sensitive`, private browser windows).
            clipboard = {
              enabled = true;
              preferences = {
                monitoring = true;
                ignorePasswords = true;
                eraseOnStartup = false;
              };
            };

            # Launch each app in its own systemd scope instead of inside
            # vicinae.service's cgroup (survives daemon restarts, proper
            # per-app resource accounting).
            applications.preferences.launchPrefix = "${lib.getExe pkgs.app2unit} --";

            # File index: the whole home dir. vicinae already skips symlinks
            # (nix `result` links), VCS dirs, node_modules, .cache, venvs,
            # CACHEDIR.TAG dirs and honours .gitignore; exclude the bulky
            # state dirs it doesn't know about.
            files.preferences = {
              indexingPaths = [home];
              excludedIndexingPaths = map (p: "${home}/${p}") [
                ".local/share/Steam"
                ".local/share/containers"
                ".local/state"
                ".mozilla"
                ".thunderbird"
                ".config/chromium"
                ".config/VSCodium"
                ".vscode-oss"
              ];
            };
          };
        };
      };
    };
  };
}
