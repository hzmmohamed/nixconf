{inputs, ...}: {
  flake.nixosModules.ai-server = {
    pkgs,
    lib,
    config,
    ...
  }: let
    llama-cpp-cuda = inputs.llama-cpp.packages.${pkgs.system}.cuda;
    llama-server = lib.getExe' llama-cpp-cuda "llama-server";
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
          "qwen3.5:9b" = {
            cmd = "${llama-server} -hf unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL --port \${PORT} --ctx-size 16384 --batch-size 2048 --ubatch-size 2048 --threads 1 --gpu-layers 99 --jinja --chat-template-kwargs '{\"enable_thinking\":true}'";
          };
          "qwen3.5:9b-nothinker" = {
            cmd = "${llama-server} -hf unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL --port \${PORT} --ctx-size 16384 --batch-size 2048 --ubatch-size 2048 --threads 1 --gpu-layers 99 --jinja --chat-template-kwargs '{\"enable_thinking\":false}'";
          };
          "qwen3.5:35b-a3b" = {
            cmd = "${llama-server} -hf unsloth/Qwen3.5-35B-A3B-GGUF:UD-Q4_K_XL --port \${PORT} --ctx-size 16384 --batch-size 2048 --ubatch-size 512 --threads 8 --gpu-layers 99 --jinja";
          };
          "qwen3.5:4b" = {
            cmd = "${llama-server} -hf unsloth/Qwen3.5-4B-GGUF:Q8_0 --port \${PORT} --ctx-size 16384 --batch-size 2048 --ubatch-size 2048 --threads 1 --gpu-layers 99 --jinja";
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

    # --- Wyoming Piper (TTS) ---
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
      };
      settings = {
        version = "1.2.1";
        cache = true;
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
