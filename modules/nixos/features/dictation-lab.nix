# Dictation training lab hub (docs/plans/2026-11-25-dictation-training-lab-
# design.md): `dictate-lab serve` as a user service. Every delivered draft
# (Pollen, `dictate` on the laptops) is uploaded here and normalized into
# ~/<dataDir>/drafts/<origin>/<id>/ (meta.json, segments.jsonl, audio.opus);
# later stages (suspects, the correction game, vocabulary and rules) read it.
#
# Reach: the tailnet only. The port is not in preferences.trustedNetworks,
# and the server itself lets in loopback and the user's own untagged
# tailnet devices only (`tailscale whois`; anything else gets 403). Runs as
# the user (the data is the user's): the host needs lingering (butternut's
# agent-host sets it). Retention: full audio is dropped after `audioDays`
# except `keepAudioLanguages`; text and segments are kept.
{self, ...}: {
  flake.nixosModules.dictation-lab = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.dictation-lab;
    user = config.preferences.user.name;
    home = config.users.users.${user}.home;

    lab = pkgs.writers.writePython3Bin "dictate-lab" {
      flakeIgnore = ["E501" "W503"];
    } (builtins.readFile ./dictation-lab/dictate-lab.py);

    path = lib.makeBinPath [config.services.tailscale.package pkgs.opus-tools];
    dataDir = "${home}/${cfg.dataDir}";
  in {
    options.preferences.dictation-lab = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8181;
        description = "Port of the lab's inbox (tailnet only).";
      };

      dataDir = lib.mkOption {
        type = lib.types.str;
        default = ".local/state/dictation/lab";
        description = "Where drafts are kept, relative to the user's home.";
      };

      audioDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 90;
        description = "Days a draft's full audio is kept (text and segments are kept for good).";
      };

      keepAudioLanguages = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["ar"];
        description = "Languages whose audio is never pruned (the likeliest fine-tuning data).";
      };

      url = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "http://${config.networking.hostName}.${self.tailnet.domain}:${toString cfg.port}";
        defaultText = lib.literalExpression ''"http://''${config.networking.hostName}.''${self.tailnet.domain}:''${toString port}"'';
        description = "The inbox URL clients upload to (MagicDNS FQDN).";
      };
    };

    config = {
      home-manager.users.${user} = {
        systemd.user.services.dictation-lab = {
          Unit.Description = "Dictation training lab: inbox for drafts (tailnet only)";
          Service = {
            ExecStart = "${lib.getExe lab} serve --data-dir ${dataDir} --port ${toString cfg.port}";
            Environment = ["PATH=${path}"];
            Restart = "on-failure";
            RestartSec = 10;
            Nice = 5;
          };
          Install.WantedBy = ["default.target"];
        };
        systemd.user.services.dictation-lab-prune = {
          Unit.Description = "Dictation training lab: drop old draft audio";
          Service = {
            Type = "oneshot";
            ExecStart = "${lib.getExe lab} prune --data-dir ${dataDir} --audio-days ${toString cfg.audioDays} --keep-lang ${lib.escapeShellArgs cfg.keepAudioLanguages}";
          };
        };
        systemd.user.timers.dictation-lab-prune = {
          Unit.Description = "Drop old dictation lab audio daily";
          Timer = {
            OnCalendar = "daily";
            Persistent = true;
            RandomizedDelaySec = "1h";
          };
          Install.WantedBy = ["timers.target"];
        };
      };

      persistance.data.directories = [cfg.dataDir];
    };
  };

  # dictate-lab's inbox and retention: dictation-lab/tests, stdlib unittest.
  perSystem = {pkgs, ...}: {
    checks.dictation-lab = pkgs.runCommand "dictation-lab-check" {nativeBuildInputs = [pkgs.python3 pkgs.opus-tools];} ''
      cp -r ${./dictation-lab} dictation-lab
      export HOME=$TMPDIR
      python3 -m unittest discover -s dictation-lab/tests -v
      touch $out
    '';
  };
}
