# Speech-to-text server for the `dictate` clients (dictation feature):
# whisper.cpp `whisper-server`, Whisper large-v3-turbo (q8_0, multilingual)
# on the GPU through Vulkan (no CUDA toolkit: the Vulkan build is on
# cache.nixos.org and, on butternut's RTX 3050, transcribes 22 s of speech
# in under 1 s including model load). Silero VAD trims silence, which also
# stops Whisper's "Thank you." hallucinations on empty audio.
#
# API: POST /inference (multipart: file, language, response_format=json,
# prompt) -> {"text": ...}; GET / is the readiness probe.
#
# Idle unload (`idleStopSec`): systemd owns the port and starts the server
# on the first connection (the client's probe at key press, so the model
# loads while the user speaks); systemd-socket-proxyd exits after the idle
# time, the server stops with it and the ~1.2 GB of VRAM is free again for
# CUDA work. `null` keeps it loaded.
#
# Reachable on the tailnet (tailscale0 is trusted) and on trusted networks
# (home LAN, cable) through preferences.trustedNetworks. No authentication:
# never open it on untrusted interfaces.
#
# Phone profile (`phone.enable`, for the Nixconf Android app, apps/phone/):
# darkhttpd on `phone.port`, same reach as the server (tailnet + trusted
# networks, no authentication), serving /var/lib/phone-profile:
#   profile.json      servers, languages, Whisper prompt (fleet vocabulary),
#                     draft retention, the on-phone Parakeet model (file
#                     names, sizes, sha256 and URLs) and how recordings are
#                     cut and delivered (pauseMs, maxSegmentSec: the laptops'
#                     values; mode), when a recording without speech stops
#                     itself (noSpeechSec) (`phone.profile`; its shape is checked
#                     against the app by checks.phone-profile)
#   models/parakeet/  the Parakeet int8 files (self.dictationModels, the same
#                     pins as the laptops)
#   app.json, app/    the published release APK, written by
#                     `nix run .#phone-app -- publish` as the user (no redeploy)
#   power.json        {"onBattery": bool}: whether this host runs on battery
#                     (a battery and no charger online), rewritten on every
#                     power_supply change (udev) and each minute; the
#                     keyboard's Auto passes over a server on battery
#                     (`phone.power` lists where each server's status is)
# URLs use the MagicDNS FQDN (`phone.url`: http://<host>.<tailnet domain>:port),
# which `phone-app` also builds into the app as its default profile URL.
# profile.json and models/ are symlinks into the store, relinked (as root)
# each time the unit starts; darkhttpd opens paths with plain open(), so it
# follows them, and runs as a dynamic user with read-only access.
{self, ...}: {
  flake.nixosModules.dictation-server = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.dictation-server;
    inherit (cfg) phone;
    user = config.preferences.user.name;
    models = self.dictationModels pkgs;
    backendPort = cfg.port + 1;
    idle = cfg.idleStopSec != null;
    listenPort =
      if idle
      then backendPort
      else cfg.port;

    turbo = pkgs.fetchurl {
      url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q8_0.bin";
      hash = "sha256-MX62nBFnPJ3h4fDUWbJTmZgE7HGsTCPBfs9fviTiWaE=";
    };
    sileroVad = pkgs.fetchurl {
      url = "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin";
      hash = "sha256-KqJpt4XutTqCmDogUB3ffB2cSOM6tjpBORrGyff7aYc=";
    };

    server = lib.escapeShellArgs ([
        (lib.getExe' cfg.package "whisper-server")
        "--host"
        (
          if idle
          then "127.0.0.1"
          else "0.0.0.0"
        )
        "--port"
        (toString listenPort)
        "--model"
        "${cfg.model}"
        "--threads"
        (toString cfg.threads)
        "--suppress-nst"
        "--vad"
        "--vad-model"
        "${sileroVad}"
      ]
      ++ cfg.extraArgs);

    # 1 s of silence, sent with VAD off: runs the encoder once so the GPU
    # pipelines exist before the first real dictation.
    silence = pkgs.runCommand "silence-1s.wav" {nativeBuildInputs = [pkgs.sox];} ''
      sox -n -r 16000 -c 1 -b 16 -t wav $out trim 0 1
    '';

    # Up + warm before the unit counts as started (the proxy waits for it).
    waitReady = pkgs.writeShellScript "dictation-server-ready" ''
      url=http://127.0.0.1:${toString listenPort}
      for _ in $(seq 300); do
        if ${lib.getExe pkgs.curl} -fs -o /dev/null "$url/"; then
          ${lib.getExe pkgs.curl} -fs -o /dev/null -m 120 "$url/inference" \
            -F file=@${silence} -F vad=false -F response_format=json || true
          exit 0
        fi
        sleep 0.1
      done
      echo "whisper-server did not come up" >&2
      exit 1
    '';

    stateDir = "/var/lib/phone-profile";
    # MagicDNS FQDN: the phone's resolver may not search the tailnet domain.
    tailnetName = "${config.networking.hostName}.${self.tailnet.domain}";
    phoneUrl = "http://${tailnetName}:${toString phone.port}";
    ownServer = "http://${tailnetName}:${toString cfg.port}";
    parakeetFiles = ["encoder.int8.onnx" "decoder.int8.onnx" "joiner.int8.onnx" "tokens.txt"];

    profile =
      pkgs.runCommand "phone-profile.json" {
        nativeBuildInputs = [pkgs.jq];
        modelDir = models.parakeet;
        modelFiles = parakeetFiles;
        modelUrl = "${phoneUrl}/models/parakeet";
        base = builtins.toJSON {
          version = 1;
          inherit (phone) servers defaultLanguage languages prompt keepDays pauseMs maxSegmentSec mode noSpeechSec power;
          localModel = {
            name = "parakeet-tdt-0.6b-v2-int8";
            language = "en";
            archive = {
              inherit (models.parakeetArchive) url;
              sha256 = builtins.convertHash {
                inherit (models.parakeetArchive) hash;
                toHashFormat = "base16";
              };
            };
          };
          appUrl = "${phoneUrl}/app.json";
        };
      } ''
        bash ${./dictation/phone-profile.sh}
      '';

    modelsDir = pkgs.linkFarm "phone-profile-models" [
      {
        name = "parakeet";
        path = models.parakeet;
      }
    ];

    # Root (ExecStartPre=+): the state dir belongs to the user, who publishes
    # APKs into it; -T never follows an existing link.
    linkStore = pkgs.writeShellScript "phone-profile-link" ''
      set -eu
      ln -sfnT ${profile} ${stateDir}/profile.json
      ln -sfnT ${modelsDir} ${stateDir}/models
    '';

    # Written as root into the user's state dir, read by darkhttpd.
    writePower = pkgs.writeShellScript "phone-power" ''
      set -eu
      battery=0 online=0
      for s in /sys/class/power_supply/*; do
        type=$(cat "$s/type" 2>/dev/null || true)
        case $type in
          Battery) battery=1 ;;
          Mains | USB)
            if [ "$(cat "$s/online" 2>/dev/null || true)" = 1 ]; then online=1; fi
            ;;
        esac
      done
      if [ $battery = 1 ] && [ $online = 0 ]; then on=true; else on=false; fi
      tmp=$(mktemp ${stateDir}/.power.XXXXXX)
      printf '{"onBattery": %s}\n' "$on" >"$tmp"
      chmod 0644 "$tmp"
      mv -f "$tmp" ${stateDir}/power.json
    '';

    mimeTypes = pkgs.writeText "phone-profile-mime.types" ''
      application/vnd.android.package-archive apk
    '';
  in {
    options.preferences.dictation-server = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8178;
        description = "Public port (the backend uses port + 1 on loopback when idle-stopping).";
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.whisper-cpp-vulkan;
        defaultText = lib.literalExpression "pkgs.whisper-cpp-vulkan";
        description = ''
          whisper.cpp build. `pkgs.whisper-cpp.override { cudaSupport = true; }`
          is in cache.nixos-cuda.org (2.3 GB closure) but not needed for speed.
        '';
      };

      model = lib.mkOption {
        type = lib.types.path;
        default = turbo;
        defaultText = "ggml-large-v3-turbo-q8_0.bin (874 MB, pinned)";
        description = "GGML Whisper model.";
      };

      vulkanDriverFiles = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json";
        description = "Restrict Vulkan to these ICDs (pick the dGPU on hybrid laptops).";
      };

      threads = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4;
        description = "CPU threads (decoder bookkeeping; the model runs on the GPU).";
      };

      idleStopSec = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = 900;
        description = "Stop the server (free VRAM) after this long without a connection; null = always loaded.";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Extra whisper-server arguments.";
      };

      phone = {
        enable = lib.mkEnableOption "the phone profile, Parakeet files and APKs over HTTP (Nixconf Android app)";

        port = lib.mkOption {
          type = lib.types.port;
          default = 8180;
          description = "Port of the profile/model/APK server (tailnet + trusted networks only).";
        };

        servers = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ownServer];
          defaultText = lib.literalExpression ''["http://''${config.networking.hostName}.''${self.tailnet.domain}:''${toString config.preferences.dictation-server.port}"]'';
          description = "Whisper servers the phone tries, in order (MagicDNS FQDNs).";
        };

        defaultLanguage = lib.mkOption {
          type = lib.types.str;
          default = "en";
          description = "Language the keyboard starts in (one of `languages`).";
        };

        languages = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = ["en" "ar"];
          description = "Languages the keyboard's toggle cycles through (Whisper codes; on-phone Parakeet is English only).";
        };

        prompt = lib.mkOption {
          type = lib.types.str;
          default = lib.concatStringsSep ", " self.dictationVocabulary + ".";
          defaultText = lib.literalExpression ''lib.concatStringsSep ", " self.dictationVocabulary + "."'';
          description = "Whisper initial prompt sent by the phone (fleet vocabulary, modules/dictation-vocabulary.nix).";
        };

        keepDays = lib.mkOption {
          type = lib.types.ints.positive;
          default = 7;
          description = "Days the phone keeps delivered and cancelled drafts (pending ones are never pruned).";
        };

        # The segmenter's settings follow this host's dictation feature
        # (the laptops' defaults when it is not imported here).
        pauseMs = lib.mkOption {
          type = lib.types.ints.between 250 2000;
          default = config.preferences.dictation.pauseMs or 550;
          defaultText = lib.literalExpression "config.preferences.dictation.pauseMs or 550";
          description = "Silence that closes a segment on the phone (it is then transcribed while recording goes on).";
        };

        maxSegmentSec = lib.mkOption {
          type = lib.types.ints.between 5 30;
          default = config.preferences.dictation.maxSegmentSec or 25;
          defaultText = lib.literalExpression "config.preferences.dictation.maxSegmentSec or 25";
          description = "Continuous speech is split at its quietest point before this length (phone).";
        };

        noSpeechSec = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = config.preferences.dictation.noSpeechSec or 10;
          defaultText = lib.literalExpression "config.preferences.dictation.noSpeechSec or 10";
          description = "A phone recording with no speech in its first this-many seconds stops itself and says so (0: never).";
        };

        mode = lib.mkOption {
          type = lib.types.enum ["batch" "stream"];
          default = "batch";
          description = ''
            `batch`: the phone types the whole text when you stop. `stream`:
            the text shows in the field as composing text, segment by segment,
            and is committed when you stop (some apps handle composing text
            poorly, hence not the default).
          '';
        };

        power = lib.mkOption {
          type = lib.types.listOf (lib.types.submodule {
            options = {
              server = lib.mkOption {
                type = lib.types.str;
                description = "A URL of `servers`.";
              };
              url = lib.mkOption {
                type = lib.types.str;
                description = "Its host's power.json (MagicDNS FQDN).";
              };
            };
          });
          default = lib.optional (lib.elem ownServer phone.servers) {
            server = ownServer;
            url = "${phoneUrl}/power.json";
          };
          defaultText = lib.literalExpression ''[{server = <this host's server>; url = "''${phone.url}/power.json";}] (if it is in servers)'';
          description = ''
            Where the phone reads whether a server's host runs on battery
            (`power.json` of that host's phone profile). A server without an
            entry counts as plugged in.
          '';
        };

        url = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = phoneUrl;
          defaultText = lib.literalExpression ''"http://''${config.networking.hostName}.''${self.tailnet.domain}:''${toString phone.port}"'';
          description = "Base URL of the profile/model/APK server (`phone-app` builds `<url>/profile.json` into the app).";
        };

        profile = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          default = profile;
          defaultText = "profile.json built from the options above";
          description = "The generated profile.json (served at /profile.json; checks.phone-profile).";
        };
      };
    };

    config = lib.mkMerge [
      {
        systemd.services.dictation-server = {
          description = "Speech-to-text server for dictation (whisper.cpp)";
          after = ["network.target"];
          wantedBy = lib.mkIf (!idle) ["multi-user.target"];
          # Persistent shader/pipeline caches: without them every cold
          # start recompiles the Vulkan pipelines (~8 s on the RTX 3050,
          # 0.3 s with the cache).
          environment =
            {
              __GL_SHADER_DISK_CACHE = "1";
              __GL_SHADER_DISK_CACHE_PATH = "/var/cache/dictation-server";
              __GL_SHADER_DISK_CACHE_SKIP_CLEANUP = "1";
              XDG_CACHE_HOME = "/var/cache/dictation-server";
            }
            // lib.optionalAttrs (cfg.vulkanDriverFiles != null) {
              VK_DRIVER_FILES = cfg.vulkanDriverFiles;
              VK_ICD_FILENAMES = cfg.vulkanDriverFiles;
            };
          unitConfig = lib.mkIf idle {StopWhenUnneeded = true;};
          serviceConfig = {
            ExecStart = server;
            ExecStartPost = waitReady;
            DynamicUser = true;
            CacheDirectory = "dictation-server";
            SupplementaryGroups = ["video" "render"];
            WorkingDirectory = "/tmp";
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            NoNewPrivileges = true;
            Restart = "on-failure";
            RestartSec = 5;
          };
        };

        preferences.trustedNetworks.allowedTCPPorts = [cfg.port];
      }

      (lib.mkIf idle {
        systemd.sockets.dictation-server-proxy = {
          description = "Speech-to-text server socket (starts it on demand)";
          wantedBy = ["sockets.target"];
          listenStreams = [(toString cfg.port)];
        };
        systemd.services.dictation-server-proxy = {
          description = "Speech-to-text server proxy (idle stop)";
          requires = ["dictation-server.service"];
          after = ["dictation-server.service"];
          serviceConfig = {
            ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --exit-idle-time=${toString cfg.idleStopSec} 127.0.0.1:${toString backendPort}";
            DynamicUser = true;
          };
        };
      })

      (lib.mkIf phone.enable {
        assertions = [
          {
            assertion = lib.elem phone.defaultLanguage phone.languages;
            message = "preferences.dictation-server.phone.defaultLanguage must be one of phone.languages.";
          }
        ];

        systemd.tmpfiles.rules = [
          "d ${stateDir} 0755 ${user} ${config.users.users.${user}.group} -"
          "d ${stateDir}/app 0755 ${user} ${config.users.users.${user}.group} -"
        ];

        systemd.services.phone-profile = {
          description = "Phone profile, Parakeet files and APKs for the Nixconf app";
          wantedBy = ["multi-user.target"];
          after = ["network.target" "systemd-tmpfiles-setup.service"];
          serviceConfig = {
            ExecStartPre = "+${linkStore}";
            ExecStart = lib.escapeShellArgs [
              (lib.getExe pkgs.darkhttpd)
              stateDir
              "--port"
              (toString phone.port)
              "--ipv6"
              "--no-listing"
              "--hide-dotfiles"
              "--no-server-id"
              "--mimetypes"
              "${mimeTypes}"
            ];
            DynamicUser = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            NoNewPrivileges = true;
            Restart = "on-failure";
            RestartSec = 5;
          };
        };

        systemd.services.phone-power = {
          description = "Power status for the Nixconf app (power.json)";
          wantedBy = ["multi-user.target"];
          after = ["systemd-tmpfiles-setup.service"];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = writePower;
          };
        };
        # The udev event is what makes it prompt; the timer catches a missed one.
        systemd.timers.phone-power = {
          wantedBy = ["timers.target"];
          timerConfig = {
            OnBootSec = "1min";
            OnUnitActiveSec = "1min";
          };
        };
        services.udev.extraRules = ''
          SUBSYSTEM=="power_supply", ACTION=="change", RUN+="${pkgs.systemd}/bin/systemctl --no-block start phone-power.service"
        '';

        preferences.trustedNetworks.allowedTCPPorts = [phone.port];
      })
    ];
  };
}
