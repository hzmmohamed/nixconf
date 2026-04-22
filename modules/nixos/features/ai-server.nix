{...}: {
  flake.nixosModules.ai-server = {
    pkgs,
    lib,
    config,
    ...
  }: let
    llama-cpp-cuda = pkgs.llama-cpp.override {cudaSupport = true;};
    llama-server = lib.getExe' llama-cpp-cuda "llama-server";

    kokoroPython = pkgs.python313.withPackages (ps: [
      ps.kokoro
      ps.fastapi
      ps.uvicorn
      ps.soundfile
      ps.numpy
    ]);

    kokoroServer = pkgs.writeTextFile {
      name = "kokoro_server.py";
      text = ''
        import io
        import numpy as np
        import soundfile as sf
        from fastapi import FastAPI, HTTPException
        from fastapi.responses import StreamingResponse
        from pydantic import BaseModel
        from kokoro import KPipeline

        app = FastAPI()

        # Load pipeline once at startup — uses CUDA if available
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
    };
  in {
    # Use prebuilt mongodb-ce instead of building mongodb from source
    nixpkgs.overlays = [
      (_final: prev: {
        mongodb = prev.mongodb-ce;
      })
    ];

    # --- llama-swap ---
    services.llama-swap = {
      enable = true;
      listenAddress = "0.0.0.0";
      port = 9292;
      openFirewall = true;
      settings = {
        healthCheckTimeout = 600;
        ttl = 3600;

        models = {
          "qwen3.5:9b-coding" = {
            cmd =
              "${llama-server} "
              + "-hf unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL "
              + "--alias qwen3.5:9b-coding "
              + # <--- This makes it official in the API
              "--port \${PORT} "
              + "--ctx-size 131072 "
              + # Fixes the 16k limit error
              "--batch-size 4096 "
              + # Faster prefill
              "--ubatch-size 1024 "
              + # Better VRAM stability
              "--threads 14 "
              + # Utilizes your CPU (from 1 -> 14)
              "--gpu-layers 99 "
              + "--reasoning "
              + # Modern replacement for thinking kwarg
              "-fa "
              + # Flash Attention (Keep this!)
              "-ctk q8_0 -ctv q8_0 "
              + # Keep these for KV cache efficiency
              "--no-webui "
              + "--spec-type ngram-simple"; # Optional: Keep for speed, remove if code logic feels "jittery"
          };
          "qwen3.5:9b" = {
            cmd = "${llama-server} -hf unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL --port \${PORT} --ctx-size 16384 --batch-size 2048 --ubatch-size 2048 --threads 1 --gpu-layers 99 --jinja --chat-template-kwargs '{\"enable_thinking\":true}' -fa -ctk q8_0 -ctv q8_0 --no-webui --spec-type ngram-simple";
          };
          "qwen3.5:9b-nothinker" = {
            cmd = "${llama-server} -hf unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL --port \${PORT} --ctx-size 16384 --batch-size 2048 --ubatch-size 2048 --threads 1 --gpu-layers 99 --jinja --chat-template-kwargs '{\"enable_thinking\":false}' -fa -ctk q8_0 -ctv q8_0 --no-webui --spec-type ngram-simple";
          };
          "qwen3.5:35b-a3b" = {
            cmd = "${llama-server} -hf unsloth/Qwen3.5-35B-A3B-GGUF:UD-Q4_K_XL --port \${PORT} --ctx-size 16384 --batch-size 2048 --ubatch-size 512 --threads 8 --gpu-layers 99 --jinja -fa -ctk q8_0 -ctv q8_0 --no-webui --spec-type ngram-simple";
          };
          "qwen3.5:4b" = {
            cmd = "${llama-server} -hf unsloth/Qwen3.5-4B-GGUF:Q8_0 --port \${PORT} --ctx-size 16384 --batch-size 2048 --ubatch-size 2048 --threads 1 --gpu-layers 99 --jinja -fa -ctk q8_0 -ctv q8_0 --no-webui --spec-type ngram-simple";
          };
          "embeddinggemma:300m" = {
            cmd = "${llama-server} -hf ggml-org/embeddinggemma-300M-GGUF --port \${PORT} --embeddings --batch-size 2048 --ubatch-size 2048 --gpu-layers 99";
          };
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
      environment.XDG_CACHE_HOME = "/var/cache/llama.cpp";
      serviceConfig.CacheDirectory = "llama.cpp";
    };

    # --- Wyoming Faster Whisper (STT) ---
    services.wyoming.faster-whisper.servers.english = {
      enable = true;
      model = "large-v3";
      language = "en";
      device = "cuda";
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
        # Use CUDA if available
        PYTORCH_CUDA_ALLOC_CONF = "max_split_size_mb:512";
      };
      serviceConfig = {
        Type = "simple";
        ExecStart = "${kokoroPython}/bin/uvicorn --app-dir ${builtins.dirOf kokoroServer} kokoro_server:app --host 127.0.0.1 --port 8880";
        Restart = "on-failure";
        RestartSec = 10;
        CacheDirectory = "kokoro-tts";
        # CUDA needs access to GPU devices
        PrivateDevices = false;
      };
    };

    # --- Wyoming Piper (TTS) — kept for Home Assistant / Wyoming satellites ---
    services.wyoming.piper.servers.english = {
      enable = true;
      voice = "en-us-ryan-high";
      uri = "tcp://0.0.0.0:10200";
      useCUDA = true;
    };

    # --- Wyoming OpenWakeWord ---
    services.wyoming.openwakeword = {
      enable = true;
      uri = "tcp://0.0.0.0:10400";
    };

    # --- Qdrant Vector Database ---
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

    # --- SearXNG ---
    services.searx = {
      enable = true;
      environmentFile = config.sops.secrets."searx_secret_key".path;
      settings = {
        server = {
          bind_address = "127.0.0.1";
          port = 8080;
          secret_key = "@SEARX_SECRET_KEY@";
        };
        search.formats = ["json"];
      };
    };

    sops.secrets."searx_secret_key" = {
      sopsFile = ../../../secrets/shared/ai-search.yaml;
      owner = "searx";
    };

    # --- LibreChat secrets ---
    sops.secrets."librechat_creds_key" = {
      sopsFile = ../../../secrets/shared/librechat.yaml;
    };
    sops.secrets."librechat_creds_iv" = {
      sopsFile = ../../../secrets/shared/librechat.yaml;
    };
    sops.secrets."librechat_jwt_secret" = {
      sopsFile = ../../../secrets/shared/librechat.yaml;
    };
    sops.secrets."librechat_jwt_refresh_secret" = {
      sopsFile = ../../../secrets/shared/librechat.yaml;
    };

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
        HOST = "0.0.0.0";
        ALLOW_REGISTRATION = true;
        ALLOW_SOCIAL_LOGIN = false;
        SEARCH = "true";
        SEARXNG_URL = "http://127.0.0.1:8080";
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
          stt = {
            openai = {
              url = "http://localhost:10300/v1/audio/transcriptions";
              model = "whisper";
            };
          };
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
    networking.firewall.allowedTCPPorts = [
      3080 # librechat
      10200 # piper TTS
      10300 # whisper STT
      10400 # openwakeword
      6333 # qdrant
    ];

    # --- Packages ---
    environment.systemPackages = [
      llama-cpp-cuda
    ];
  };
}
