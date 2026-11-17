# Push-to-talk dictation into any window (Sway), online or offline.
#
#   Mod4+d  hold: record while held, transcribe and type on release
#           tap:  latch (toggle mode), tap again to stop
#   Mod4+Ctrl+d  cancel the running recording
#
# One client, `dictate` (dictation/dictate.sh), picks the engine per
# dictation while you speak:
#   1. the first reachable `servers` entry: whisper.cpp `whisper-server`
#      (dictation-server feature; butternut's RTX 3050 runs Whisper
#      large-v3-turbo, multilingual), over the cable or the tailnet;
#   2. otherwise this machine: Parakeet TDT 0.6B v2 (int8 ONNX, sherpa-onnx)
#      on the CPU for English, Whisper small (whisper.cpp, Vulkan iGPU or
#      CPU) for other languages.
# The language follows the active keyboard layout (`layoutLanguages`).
# The text is typed with wtype (falls back to the clipboard).
#
# Battery: no model is resident while idle. The local engine is a
# socket-activated user service: the press itself sends GET /ready (model
# loads while you speak) and it exits after `localIdleSec`.
#
# Indicator: a waybar module in the activity column (recording = error
# colour, transcribing = accent, from the theme palette) plus one
# replaceable notification. Recording uses the default source, so
# WirePlumber's headset autoswitch and the DeepFilter mic apply as usual.
# Claude Code's own voice mode (SoX `rec`) is unaffected.
#
# T3 Code: its transcription runs transcribe.cpp (GGUF) inside the T3
# server of the chosen environment, downloading into its state dir. With
# `t3code.provideModels` the Parakeet GGUF it defaults to is pinned here and
# put where T3 looks for existing copies (the Hugging Face cache layout), so
# T3's "Download" links it offline in a second.
#
# Models are fixed-output fetches pinned by hash: nothing is downloaded at
# dictation time.
{...}: {
  flake.nixosModules.dictation = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.dictation;
    user = config.preferences.user.name;
    waybarSignal = 14;
    localSocket = "%t/dictate/local.sock";

    # sherpa-onnx export of nvidia/parakeet-tdt-0.6b-v2 (English, punctuated).
    parakeet = pkgs.stdenvNoCC.mkDerivation {
      pname = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8";
      version = "2025-05";
      src = pkgs.fetchurl {
        url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2";
        hash = "sha256-b8RCa1SqVJoAGbinW43qWRZOcXkKN6xWoEWtV/kV9xQ=";
      };
      dontConfigure = true;
      dontBuild = true;
      installPhase = ''
        mkdir -p $out
        cp encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt $out/
      '';
    };

    # Multilingual fallback for non-English offline (190 MB).
    whisperSmall = pkgs.fetchurl {
      url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small-q5_1.bin";
      hash = "sha256-roXkqTXXpWe9EC/lWvwWu1lb22GOEbL8dZG8CBIEEbs=";
    };

    # T3 Code's default model and its Silero VAD, exactly as in T3's speech
    # catalog (id, revision, sha256): T3 re-hashes linked files.
    t3Models = {
      "handy-computer/parakeet-unified-en-0.6b-gguf" = {
        revision = "7e948f21b7bdbac698d3318db9d350f1096f3b6c";
        filename = "parakeet-unified-en-0.6b-Q8_0.gguf";
        hash = "sha256-S1C23YYr9uNGkpqvT16qzsADv6P1ZGLWyHS0HvLzh5U=";
      };
      "handy-computer/silero-vad-v6.2-gguf" = {
        revision = "97bbd75179f535e4708bccdf61e9278b8b60dfc7";
        filename = "silero-vad-v6.2-F32.gguf";
        hash = "sha256-DYcagAxCD91dGxejrqQpbRw5YI8P9KkpXrdkV+sciOY=";
      };
    };
    t3ModelFiles = lib.mapAttrs' (id: m: {
      name = ".cache/huggingface/hub/models--${lib.replaceStrings ["/"] ["--"] id}/snapshots/${m.revision}/${m.filename}";
      value.source = pkgs.fetchurl {
        url = "https://huggingface.co/${id}/resolve/${m.revision}/${m.filename}";
        inherit (m) hash;
      };
    }) (lib.filterAttrs (id: _: lib.elem id cfg.t3code.models) t3Models);

    localEngine = pkgs.writers.writePython3Bin "dictate-local" {
      libraries = ps: [ps.sherpa-onnx ps.numpy];
      flakeIgnore = ["E501"];
    } (builtins.readFile ./dictation/dictate-local.py);

    whisperCli = cfg.localWhisperPackage;

    preamble = ''
      cfg_servers=${lib.escapeShellArg (lib.concatStringsSep " " cfg.servers)}
      cfg_local_socket="''${XDG_RUNTIME_DIR:?}/dictate/local.sock"
      cfg_local_lang=en
      cfg_whisper_model=${lib.escapeShellArg (lib.optionalString cfg.localMultilingual "${whisperSmall}")}
      cfg_threads=${toString cfg.threads}
      cfg_output="${cfg.output}"
      cfg_append_space=${
        if cfg.appendSpace
        then "1"
        else "0"
      }
      cfg_prompt=${lib.escapeShellArg cfg.prompt}
      cfg_max_sec=${toString cfg.maxSeconds}
      cfg_tap_ms=${toString cfg.tapMs}
      cfg_waybar_signal=${toString waybarSignal}

      layout_lang() {
        case "$1" in
      ${lib.concatStrings (lib.mapAttrsToList (layout: lang: "  *${lib.escapeShellArg layout}*) echo ${lang} ;;\n") cfg.layoutLanguages)}  *) echo ${cfg.defaultLanguage} ;;
        esac
      }

    '';

    dictate = pkgs.writeShellApplication {
      name = "dictate";
      runtimeInputs =
        [
          pkgs.coreutils
          pkgs.curl
          pkgs.gnused
          pkgs.jq
          pkgs.libnotify
          pkgs.pipewire # pw-record
          pkgs.sway # swaymsg
          pkgs.systemd
          pkgs.util-linux # flock
          pkgs.wl-clipboard
          pkgs.wtype
        ]
        ++ lib.optional cfg.localMultilingual whisperCli;
      text = preamble + builtins.readFile ./dictation/dictate.sh;
    };

    exe = lib.getExe dictate;
  in {
    options.preferences.dictation = {
      servers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["http://butternut-cable:8178" "http://butternut:8178"];
        description = ''
          whisper.cpp servers (dictation-server feature), tried in order and
          probed in parallel at each key press; the first reachable one
          transcribes. Empty or none reachable: the local engine.
        '';
      };

      key = lib.mkOption {
        type = lib.types.str;
        default = "Mod4+d";
        description = "Sway key: hold to dictate, tap to latch. `Mod4+Ctrl+<key>` cancels.";
      };

      defaultLanguage = lib.mkOption {
        type = lib.types.str;
        default = "en";
        description = "Language for keyboard layouts not in `layoutLanguages` (whisper code or `auto`).";
      };

      layoutLanguages = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {Arabic = "ar";};
        description = ''
          Substring of the active XKB layout name -> spoken language. Typing
          Arabic means switching the layout anyway, so dictation follows it.
        '';
      };

      localMultilingual = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Offline fallback for non-English languages: Whisper small (q5_1,
          190 MB) through whisper.cpp. Parakeet is English-only.
        '';
      };

      localWhisperPackage = lib.mkOption {
        type = lib.types.package;
        default = pkgs.whisper-cpp-vulkan;
        defaultText = lib.literalExpression "pkgs.whisper-cpp-vulkan";
        description = "whisper.cpp for the local multilingual fallback (Vulkan uses the iGPU; it falls back to the CPU).";
      };

      threads = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4;
        description = "CPU threads for the local engines.";
      };

      localIdleSec = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = "The local engine exits (frees ~1 GB RAM) after this long without a dictation.";
      };

      output = lib.mkOption {
        type = lib.types.enum ["type" "paste"];
        default = "type";
        description = ''
          `type`: wtype the text (default; clipboard untouched). `paste`:
          clipboard + Ctrl+Shift+V (terminals, plain-text paste elsewhere).
        '';
      };

      appendSpace = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Type a space after each dictation, so consecutive ones don't run together.";
      };

      prompt = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "NixOS, Sway, Claude Code, T3 Code, flake, home-manager.";
        description = "Whisper initial prompt (server path only): vocabulary and style hints.";
      };

      maxSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = "Recording safety limit; it stops and transcribes at this point.";
      };

      tapMs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = "A press shorter than this latches (toggle mode) instead of push-to-talk.";
      };

      t3code = {
        provideModels = lib.mkOption {
          type = lib.types.bool;
          default = lib.attrByPath ["preferences" "agents" "role"] null config != null;
          defaultText = lib.literalMD "true when the T3 Code agent features are imported";
          description = ''
            Put T3 Code's speech models (`models`) where T3 finds existing
            copies, so its "Download" works offline and instantly.
          '';
        };
        models = lib.mkOption {
          type = lib.types.listOf (lib.types.enum (lib.attrNames t3Models));
          default = lib.attrNames t3Models;
          description = "T3 speech catalog ids to provide (731 MB + 1 MB by default).";
        };
      };

      package = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        default = dictate;
        description = "The generated `dictate` client.";
      };
    };

    config = lib.mkMerge [
      {
        home-manager.users.${user} = {
          home.packages = [dictate];

          # Local engine: socket-activated, exits when idle.
          systemd.user.sockets.dictate-local = {
            Unit.Description = "Local dictation engine socket";
            Socket = {
              ListenStream = localSocket;
              SocketMode = "0600";
              DirectoryMode = "0700";
            };
            Install.WantedBy = ["sockets.target"];
          };
          systemd.user.services.dictate-local = {
            Unit.Description = "Local dictation engine (Parakeet, CPU, on demand)";
            Service = {
              ExecStart = lib.getExe localEngine;
              Environment = [
                "DICTATE_PARAKEET=${parakeet}"
                "DICTATE_THREADS=${toString cfg.threads}"
                "DICTATE_IDLE_SEC=${toString cfg.localIdleSec}"
              ];
              # Inference bursts shouldn't fight the desktop.
              Nice = 5;
            };
          };

          # mkOptionDefault: merge with HM's defaults and the other features'
          # bindings (a plain definition would replace them all).
          wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault {
            # HM's default Mod4+d (menu, same as Mod4+space) would override
            # the --no-repeat binding: sway treats them as one binding.
            ${cfg.key} = lib.mkForce null;
            "--no-repeat ${cfg.key}" = "exec ${exe} press";
            "--release ${cfg.key}" = "exec ${exe} release";
            "Mod4+Ctrl+${lib.last (lib.splitString "+" cfg.key)}" = "exec ${exe} cancel";
          };

          home.file = lib.mkIf cfg.t3code.provideModels t3ModelFiles;
        };
      }

      (lib.mkIf (config.preferences.desktopShell == "waybar") {
        home-manager.users.${user}.programs.waybar = {
          settings.mainBar = {
            modules-center = lib.mkAfter ["custom/dictation"];
            "custom/dictation" = {
              exec = "${exe} status";
              return-type = "json";
              interval = "once";
              signal = waybarSignal;
              hide-empty-text = true;
              justify = "center";
              tooltip = true;
              on-click = "${exe} cancel";
            };
          };
          style = lib.mkAfter ''
            #custom-dictation {
              padding: 6px 0;
              margin: 2px 4px;
              border-radius: 6px;
            }
            #custom-dictation.recording { color: @error; }
            #custom-dictation.transcribing { color: @accent; }
          '';
        };
      })
    ];
  };
}
