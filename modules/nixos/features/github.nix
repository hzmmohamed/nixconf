# GitHub access through the `gh` CLI's own login: no dashboard-made tokens,
# nothing in sops (docs/plans/2026-11-22-github-auth-design.md).
#
# Each host logs in once with `gh auth login` (device flow: a code to approve
# at github.com/login/device). gh keeps the token itself: Secret Service
# (gnome-keyring) on desktops, ~/.config/gh/hosts.yml (0600) on headless
# hosts. T3 Code's PR panel and agents use that `gh`; git uses it as the
# credential helper for HTTPS to github.com (pushes stay on SSH).
{...}: {
  flake.nixosModules.github = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    gh = lib.getExe pkgs.gh;
    desktop = config.preferences.desktop.enable;

    # Offline: reads the stored token (keyring / hosts.yml), no API call, so
    # being offline never reads as "not logged in". A revoked token passes.
    loggedIn = "gh auth token --hostname github.com >/dev/null 2>&1";

    authCheck = pkgs.writeShellApplication {
      name = "github-auth-check";
      runtimeInputs = [pkgs.gh pkgs.libnotify];
      text = ''
        ${loggedIn} || notify-send -a GitHub -i dialog-password \
          "GitHub: not logged in" "Run: gh auth login"
      '';
    };
  in {
    home-manager.users.${user} = {
      programs.gh = {
        enable = true;
        settings.git_protocol = "ssh";
        # HM's helper writes HM programs.git, which this repo doesn't use
        # (git is a wrapped package); /etc/gitconfig below instead.
        gitCredentialHelper.enable = false;
      };

      # Typed `gh` in a terminal while logged out: log in first, then run
      # the command. Only with a TTY on both ends: T3 and agents exec the
      # binary (or pipe), and must fail plainly instead of blocking.
      programs.fish.functions.gh = {
        wraps = "gh";
        description = "gh, logging in to GitHub first when needed";
        body = ''
          if test "$argv[1]" != auth; and isatty stdin; and isatty stdout
              and not command ${loggedIn}
              echo "GitHub: not logged in, starting login…" >&2
              command gh auth login --web --git-protocol ssh --hostname github.com
              or return $status
          end
          command gh $argv
        '';
      };

      # Headless (fern): a one-line nag in each interactive shell until login.
      programs.fish.interactiveShellInit = lib.mkIf (!desktop) ''
        if isatty stdout; and not command ${loggedIn}
            echo "GitHub: not logged in on ${config.networking.hostName}: run gh auth login"
        end
      '';

      # Desktops: one notification per session when logged out, so T3's PR
      # panel doesn't just fail quietly.
      systemd.user.services.github-auth-check = lib.mkIf desktop {
        Unit = {
          Description = "Notify when gh is not logged in to GitHub";
          After = ["graphical-session.target"];
          PartOf = ["graphical-session.target"];
        };
        Service = {
          Type = "oneshot";
          ExecStart = lib.getExe authCheck;
        };
        Install.WantedBy = ["graphical-session.target"];
      };
    };

    # Read by the wrapped git (nixpkgs git: sysconfdir /etc). Absolute path,
    # so the helper works where gh isn't on PATH.
    environment.etc.gitconfig.text = lib.concatMapStrings (url: ''
      [credential "${url}"]
        helper = !${gh} auth git-credential
    '') ["https://github.com" "https://gist.github.com"];
  };
}
