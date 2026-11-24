{inputs, ...}: {
  flake.nixosModules.ai-server = {
    pkgs,
    lib,
    config,
    ...
  }: let
    cfg = config.preferences.ai-server;
    tailscaleIf = config.services.tailscale.interfaceName;
    librechatSecrets = ../../.. + "/secrets/${config.networking.hostName}/librechat.yaml";

    # CUDA builds of the AI packages only (docs/plans/2026-11-24-peacelily-bring-up.md,
    # "CUDA package set"): the same nixpkgs rev with cudaSupport, so nothing
    # else in the system changes. Default config on purpose (no
    # cudaCapabilities etc.): any deviation changes the store paths and
    # misses cache.nixos-cuda.org, which builds exactly this. That cache only
    # substitutes once its hydra has built our rev: check before a flake
    # update, or torch/CTranslate2/onnxruntime build from source (hours).
    pkgsCuda = import inputs.nixpkgs {
      inherit (pkgs.stdenv.hostPlatform) system;
      config = {
        allowUnfree = true;
        cudaSupport = true;
      };
    };

    llama-cpp-cuda = pkgsCuda.llama-cpp;
    llama-server = lib.getExe' llama-cpp-cuda "llama-server";

    # One flag per list element, joined with spaces: rules out the
    # `--no-mmproj--ctx-size` class of bug. Fixed ports instead of llama-swap's
    # ${PORT} so Prometheus can scrape each llama-server's /metrics directly
    # (monitoring.nix reads the `proxy` URLs): only a loaded model answers,
    # and scraping never triggers a load. llama-server binds 127.0.0.1 (its
    # default host).
    mkModel = port: args: {
      cmd = lib.concatStringsSep " " ([llama-server] ++ args ++ ["--port ${toString port}" "--metrics"]);
      proxy = "http://127.0.0.1:${toString port}";
    };

    # Shared by the chat/coding models: tool calling needs the Jinja chat
    # template (default on llama.cpp 9190; explicit so a version bump can't
    # silently drop it). q8_0 KV halves the cache vs f16 at negligible quality cost.
    chatFlags = [
      "--jinja"
      "--flash-attn on"
      "--cache-type-k q8_0"
      "--cache-type-v q8_0"
      "--no-webui"
      "--spec-type ngram-simple"
    ];

    kokoroPython = pkgsCuda.python313.withPackages (ps: [
      ps.kokoro
      ps.fastapi
      ps.uvicorn
      ps.soundfile
      ps.numpy
    ]);

    # A directory holding kokoro_server.py, for uvicorn's --app-dir.
    kokoroServer = pkgs.writeTextDir "kokoro_server.py" ''
      import io
      import numpy as np
      import soundfile as sf
      from fastapi import FastAPI, HTTPException
      from fastapi.responses import StreamingResponse
      from pydantic import BaseModel
      from kokoro import KPipeline

      app = FastAPI()

      # Load pipeline once at startup (on the GPU: torch is the CUDA build)
      pipeline = KPipeline(lang_code="a")  # "a" = American English

      VOICES = [
        "af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky",
        "am_adam", "am_michael", "am_echo",
        "bf_emma", "bf_isabella", "bm_george", "bm_daniel",
      ]

      class SpeechRequest(BaseModel):
        model: str = "kokoro"
        input: str
        voice: str = "af_heart"
        response_format: str = "wav"
        speed: float = 1.0

      @app.get("/v1/models")
      def list_models():
        return {"object": "list", "data": [{"id": "kokoro", "object": "model"}]}

      @app.post("/v1/audio/speech")
      def synthesize(req: SpeechRequest):
        if not req.input.strip():
          raise HTTPException(status_code=400, detail="input is empty")
        voice = req.voice if req.voice in VOICES else "af_heart"
        audio_chunks = []
        for _, _, audio in pipeline(req.input, voice=voice, speed=req.speed):
          audio_chunks.append(audio)
        if not audio_chunks:
          raise HTTPException(status_code=500, detail="synthesis produced no audio")
        samples = np.concatenate(audio_chunks)
        buf = io.BytesIO()
        sf.write(buf, samples, 24000, format="WAV")
        buf.seek(0)
        return StreamingResponse(buf, media_type="audio/wav")
    '';
  in {
    options.preferences.ai-server.qdrantApiKey.enable = lib.mkEnableOption ''
      a Qdrant API key from sops (secrets/<hostname>/qdrant.yaml, key
      `qdrant_api_key`; any long random string, e.g. `openssl rand -hex 32`).
      Clients then send it in the `api-key` header; the dashboard prompts for it'';

    config = {
      # Use prebuilt mongodb-ce instead of building mongodb from source
      nixpkgs.overlays = [
        (_final: prev: {
          mongodb = prev.mongodb-ce;
        })
      ];

      # --- llama-swap ---
      # OpenCode (agent-common.nix `llamaSwapUrl`) and ai-client reach this at
      # http://peacelily:9292/v1 over Tailscale (MagicDNS). It binds 0.0.0.0 so
      # the tailnet address works without knowing the Tailscale IP at eval time;
      # the firewall only admits 9292 on tailscale0 (see "Firewall" below).
      #
      # VRAM budget: RTX 5060 Ti 16 GB (docs/plans/2026-03-28-peacelily-ai-server-design.md).
      # The embedding model stays resident (~0.5 GB); one chat model is swapped in.
      # Models OpenCode uses get --parallel 1 so one session owns the whole window
      # (concurrent requests queue instead of splitting the KV cache).
      services.llama-swap = {
        enable = true;
        listenAddress = "0.0.0.0";
        port = 9292;
        openFirewall = false;
        settings = {
          healthCheckTimeout = 600;
          ttl = 3600;

          models = {
            # OpenCode `qwen-coder`. 9B Q4 (~6.5 GB) + 64k q8_0 KV fits in 16 GB.
            "qwen3.5:9b-coding" = mkModel 8010 ([
                "-hf unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL"
                "--alias qwen3.5:9b-coding"
                "--no-mmproj"
                "--ctx-size 65536"
                "--parallel 1"
                "--batch-size 4096"
                "--ubatch-size 1024"
                "--threads 14"
                "--gpu-layers 99"
                "--reasoning on"
              ]
              ++ chatFlags);
            "qwen3.5:9b" = mkModel 8011 ([
                "-hf unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL"
                "--ctx-size 32768"
                "--batch-size 2048"
                "--ubatch-size 2048"
                "--threads 1"
                "--gpu-layers 99"
                "--chat-template-kwargs '{\"enable_thinking\":true}'"
              ]
              ++ chatFlags);
            "qwen3.5:9b-nothinker" = mkModel 8012 ([
                "-hf unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL"
                "--ctx-size 32768"
                "--batch-size 2048"
                "--ubatch-size 2048"
                "--threads 1"
                "--gpu-layers 99"
                "--chat-template-kwargs '{\"enable_thinking\":false}'"
              ]
              ++ chatFlags);
            # OpenCode `qwen-moe`. ~22 GB of weights can't fit in 16 GB VRAM, so
            # no --gpu-layers: llama.cpp's --fit (default on) places layers and
            # keeps MoE expert weights on the CPU around the fixed 64k context.
            "qwen3.5:35b-a3b" = mkModel 8013 ([
                "-hf unsloth/Qwen3.5-35B-A3B-GGUF:UD-Q4_K_XL"
                "--ctx-size 65536"
                "--parallel 1"
                "--batch-size 2048"
                "--ubatch-size 512"
                "--threads 12"
              ]
              ++ chatFlags);
            # OpenCode `qwen-small` (titles, summaries) and LibreChat titles.
            "qwen3.5:4b" = mkModel 8014 ([
                "-hf unsloth/Qwen3.5-4B-GGUF:Q8_0"
                "--ctx-size 32768"
                "--batch-size 2048"
                "--ubatch-size 2048"
                "--threads 1"
                "--gpu-layers 99"
              ]
              ++ chatFlags);
            "embeddinggemma:300m" = mkModel 8015 [
              "-hf ggml-org/embeddinggemma-300M-GGUF"
              "--embeddings"
              "--batch-size 2048"
              "--ubatch-size 2048"
              "--gpu-layers 99"
            ];
          };

          groups = {
            embedding = {
              persistent = true;
              swap = false;
              exclusive = false;
              members = ["embeddinggemma:300m"];
            };
          };
        };
      };

      # Give llama-server child processes a writable cache for HF model downloads
      systemd.services.llama-swap = {
        environment = {
          XDG_CACHE_HOME = "/var/cache/llama.cpp";
        };
        serviceConfig.CacheDirectory = "llama.cpp";
      };

      # Wyoming servers bind 0.0.0.0 for Home Assistant / satellites on the
      # tailnet; the firewall admits their ports on tailscale0 only.

      # --- Wyoming Faster Whisper (STT) ---
      # turbo (large-v3-turbo) at int8_float16 holds ~1.5 GB of VRAM, so it
      # fits beside the largest llama-swap model; large-v3 (~3-4 GB) doesn't.
      services.wyoming.faster-whisper.package = pkgsCuda.wyoming-faster-whisper;
      services.wyoming.faster-whisper.servers.english = {
        enable = true;
        model = "turbo";
        language = "en";
        device = "cuda";
        # "auto" + en adds the sherpa (Parakeet) deps to the package, unused
        # once a Whisper model is named.
        sttLibrary = "faster-whisper";
        extraArgs = ["--compute-type" "int8_float16"];
        uri = "tcp://0.0.0.0:10300";
      };

      systemd.services.wyoming-faster-whisper-english.serviceConfig = {
        Restart = "on-failure";
        RestartSec = 10;
        MemoryMax = "16G";
        MemoryHigh = "14G";
      };

      # --- Kokoro TTS (OpenAI-compatible /v1/audio/speech) ---
      systemd.services.kokoro-tts = {
        description = "Kokoro TTS server";
        after = ["network.target"];
        wantedBy = ["multi-user.target"];
        environment = {
          # HF model cache
          XDG_CACHE_HOME = "/var/cache/kokoro-tts";
          PYTORCH_CUDA_ALLOC_CONF = "max_split_size_mb:512";
        };
        serviceConfig = {
          Type = "simple";
          ExecStart = "${kokoroPython}/bin/uvicorn --app-dir ${kokoroServer} kokoro_server:app --host 127.0.0.1 --port 8880";
          Restart = "on-failure";
          RestartSec = 10;
          CacheDirectory = "kokoro-tts";
          # CUDA needs access to GPU devices
          PrivateDevices = false;
        };
      };

      # --- Wyoming Piper (TTS) — kept for Home Assistant / Wyoming satellites ---
      services.wyoming.piper.package = pkgsCuda.wyoming-piper;
      services.wyoming.piper.servers.english = {
        enable = true;
        voice = "en-us-ryan-high";
        uri = "tcp://0.0.0.0:10200";
        useCUDA = true;
      };
      # The upstream unit keeps PrivateDevices and an empty DeviceAllow even
      # with useCUDA, which hides the GPU; admit the NVIDIA devices the way
      # the faster-whisper module does for device = "cuda".
      systemd.services.wyoming-piper-english.serviceConfig = {
        PrivateDevices = lib.mkForce false;
        DeviceAllow = lib.mkForce [
          "char-nvidia-uvm"
          "char-nvidia-frontend"
          "char-nvidia-caps"
          "char-nvidiactl"
        ];
      };

      # --- Wyoming OpenWakeWord ---
      services.wyoming.openwakeword = {
        enable = true;
        uri = "tcp://0.0.0.0:10400";
      };

      # --- Qdrant Vector Database ---
      # 0.0.0.0 for the dashboard bookmark (ai-client.nix); the firewall admits
      # 6333 on tailscale0 only. The API key comes from the environment
      # (QDRANT__SERVICE__API_KEY) so it never lands in the world-readable
      # store config.
      services.qdrant = {
        enable = true;
        settings = {
          storage = {
            storage_path = "/var/lib/qdrant/storage";
            snapshots_path = "/var/lib/qdrant/snapshots";
          };
          service = {
            host = "0.0.0.0";
            http_port = 6333;
          };
          telemetry_disabled = true;
        };
      };

      sops.secrets."qdrant_api_key" = lib.mkIf cfg.qdrantApiKey.enable {
        sopsFile = ../../.. + "/secrets/${config.networking.hostName}/qdrant.yaml";
      };
      sops.templates."qdrant.env" = lib.mkIf cfg.qdrantApiKey.enable {
        content = ''
          QDRANT__SERVICE__API_KEY=${config.sops.placeholder."qdrant_api_key"}
        '';
      };
      # Read by systemd (as root) before DynamicUser drops privileges.
      systemd.services.qdrant.serviceConfig.EnvironmentFile =
        lib.mkIf cfg.qdrantApiKey.enable config.sops.templates."qdrant.env".path;

      # # --- SearXNG ---
      # services.searx = {
      #   enable = true;
      #   environmentFile = config.sops.secrets."searx_secret_key".path;
      #   settings = {
      #     server = {
      #       bind_address = "127.0.0.1";
      #       port = 8080;
      #       secret_key = "@SEARX_SECRET_KEY@";
      #     };
      #     search.formats = ["json"];
      #   };
      # };

      # sops.secrets."searx_secret_key" = {
      #   sopsFile = ../../../secrets/shared/ai-search.yaml;
      #   owner = "searx";
      # };

      # --- LibreChat secrets (secrets/<hostname>/librechat.yaml) ---
      sops.secrets."librechat_creds_key".sopsFile = librechatSecrets;
      sops.secrets."librechat_creds_iv".sopsFile = librechatSecrets;
      sops.secrets."librechat_jwt_secret".sopsFile = librechatSecrets;
      sops.secrets."librechat_jwt_refresh_secret".sopsFile = librechatSecrets;

      # --- LibreChat ---
      services.librechat = {
        enable = true;
        openFirewall = false; # handled in firewall below (upstream module has a bug with cfg.port)
        enableLocalDB = true;
        credentials = {
          CREDS_KEY = config.sops.secrets."librechat_creds_key".path;
          CREDS_IV = config.sops.secrets."librechat_creds_iv".path;
          JWT_SECRET = config.sops.secrets."librechat_jwt_secret".path;
          JWT_REFRESH_SECRET = config.sops.secrets."librechat_jwt_refresh_secret".path;
        };
        env = {
          HOST = "0.0.0.0"; # firewall: tailscale0 only
          # Closed. To create the first account, deploy once with this set to
          # true, register, then set it back to false and redeploy.
          ALLOW_REGISTRATION = false;
          ALLOW_SOCIAL_LOGIN = false;
          # Conversation search needs Meilisearch (services.librechat.meilisearch,
          # plus a master key in sops); off until that exists.
          SEARCH = false;
        };
        settings = {
          version = "1.2.1";
          cache = true;
          speech = {
            tts = {
              openai = {
                url = "http://127.0.0.1:8880/v1/audio/speech";
                apiKey = "EMPTY";
                model = "kokoro";
                voices = ["af_heart" "af_bella" "af_nicole" "af_sarah" "am_adam" "am_michael" "bf_emma" "bm_george"];
              };
            };
            # No server-side STT: 10300 is the Wyoming protocol (Home
            # Assistant), not an OpenAI /v1/audio/transcriptions endpoint.
            # LibreChat falls back to the browser's speech recognition
            # (docs/plans/2026-04-03-llama-server-features-guide.md, "STT").
          };
          endpoints = {
            custom = [
              {
                name = "peacelily";
                apiKey = "sk-no-key-required";
                baseURL = "http://localhost:9292/v1";
                models = {
                  default = [
                    "qwen3.5:9b"
                    "qwen3.5:9b-nothinker"
                    "qwen3.5:35b-a3b"
                    "qwen3.5:4b"
                  ];
                };
                titleConvo = true;
                titleModel = "qwen3.5:4b";
                modelDisplayLabel = "Peacelily";
              }
            ];
          };
        };
      };

      # --- Firewall ---
      # Nothing on the global allow list: every service is tailnet-only.
      # tailscale0 is also in trustedInterfaces (tailscale.nix); this explicit
      # list documents what peacelily serves and survives dropping that.
      networking.firewall.interfaces.${tailscaleIf}.allowedTCPPorts = [
        9292 # llama-swap (OpenCode: http://peacelily:9292/v1)
        3080 # librechat
        6333 # qdrant (HTTP + dashboard)
        10200 # piper TTS
        10300 # whisper STT
        10400 # openwakeword
      ];

      # --- Packages ---
      environment.systemPackages = [
        llama-cpp-cuda
      ];
    };
  };
}
