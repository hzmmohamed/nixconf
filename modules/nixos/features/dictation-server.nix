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
{...}: {
  flake.nixosModules.dictation-server = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.dictation-server;
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
    ];
  };
}
