# attn, the attention tracker (github:hzmmohamed/attn, private), replacing
# ActivityWatch on the desks the owner works at:
#
#   attn-daemon   system unit, user `attn`: ingest-only ActivityWatch API on
#                 127.0.0.1:5600, an age-encrypted, signed frame log in
#                 /var/lib/attn, sealed segments written to the sink below.
#                 It holds only public keys: it can write the queue, never
#                 read it back.
#   attn-sensor   user unit (graphical-session.target): media-aware idle,
#                 shell cwd (fish hook, agent shells skipped), git activity.
#   awatcher      user unit: wlroots window + idle watcher (aw-watcher-window
#                 never worked on Wayland). The ActivityWatch Chromium and
#                 VS Code extensions stay and post to attn the same way.
#
# Deferred: the s3:// sink and its AWS keys (the Alchemy stack), the watcher
# token, attn secrets in sops (after the primary key leaves agent hosts) and
# the brain recipient (peacelily's host key via ssh-to-age, once it's up).
# ptrace_scope and agent deny rules belong to the agent-isolation work.
# Hosts set services.attn.device.deviceId.
{
  inputs,
  self,
  ...
}: {
  flake.nixosModules.attn = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    home = config.users.users.${user}.home;
    inherit (config.services.attn.sensor) idleCommands;
  in {
    imports = [inputs.attn.nixosModules.device];

    services.attn.device = {
      enable = true;
      # Segments stay age-encrypted on disk until the S3 sink exists.
      sink = "dir:///var/lib/attn/sink";
      recipients = [
        # The owner's offline vault key (KeePassXC: "attn vault age key").
        "age1favv7nunf736jmccarlxgc3lqrvpschs6m4xqs733jxdh09z65wqd8xkvk"
      ];
      # Holds bulk uploads on a metered link.
      # Known gap: the daemon (system user, ProtectHome) can't see the
      # user's `agent-net set` override, only NetworkManager's metered flag.
      # Harmless with the dir:// sink; matters once uploads go to S3.
      networkStatusPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.agent-net;
    };

    # On the first deploy ActivityWatch's aw-server (a user unit) may still
    # hold 127.0.0.1:5600 for a moment; the default 100 ms restart delay
    # would hit the start limit and leave the daemon failed.
    systemd.services.attn-daemon.serviceConfig.RestartSec = 5;

    services.attn.sensor = {
      enable = true;
      gitRoots = lib.mkDefault ["${home}/work" "${home}/nixconf"];
    };

    home-manager.users.${user} = {
      # Input idle for the sensor; joins the lock and screen-off timeouts of
      # features/swayidle.nix. 180 s: aw-watcher-afk's default.
      services.swayidle.timeouts = [
        {
          timeout = 180;
          command = idleCommands.idle;
          resumeCommand = idleCommands.active;
        }
      ];

      # A swayidle (re)start (caffeine ending, a switch, a crash) drops any
      # pending resume, which would leave the sensor's idle flag on while
      # the user works. Clear it on start; `-`: never block swayidle on it.
      systemd.user.services.swayidle.Service.ExecStartPre = "-${idleCommands.active}";

      # Bound to sway-session.target, not graphical-session.target's start:
      # it needs WAYLAND_DISPLAY, which sway exports only once it runs (the
      # old ActivityWatch afk watcher hit the same ordering).
      systemd.user.services.awatcher = {
        Unit = {
          Description = "awatcher: window and idle watcher (posts to attn)";
          After = ["sway-session.target"];
          PartOf = ["sway-session.target"];
        };
        Service = {
          ExecStart = lib.getExe pkgs.awatcher;
          Restart = "on-failure";
          RestartSec = 5;
        };
        Install.WantedBy = ["sway-session.target"];
      };
    };
  };
}
