# Push-to-talk dictation into any window (Sway), online or offline,
# streamed segment by segment.
#
#   Mod4+d  hold: record while held, stop on release
#           tap:  latch (toggle mode), tap again to stop
#   Mod4+Ctrl+d  cancel: the text already typed stays, the segment in
#                flight is discarded
#
#   Mod4+Alt+d   switch the mode of the next sessions (also in the picker)
#   `dictate input`  list the mics / choose one (also in the picker)
#
# Modes (`mode`, dictation/dictate-stream.py): one recording runs
# continuously; Silero VAD cuts it at natural pauses (`pauseMs`) or, in
# continuous speech, at the quietest point before `maxSegmentSec`, and each
# segment is transcribed as soon as it closes, while recording goes on.
#   batch   the whole text is pasted at once when you stop (clipboard +
#           Ctrl+V, Ctrl+Shift+V in terminals; the clipboard is restored);
#           default: record, watch the timer, stop around
#           `overlay.longSessionMinutes`, continue
#   stream  each segment is typed with wtype at its pause, in order
# (a space between segments, none before punctuation). The engine, chosen
# once per session:
#   1. the first reachable `servers` entry: whisper.cpp `whisper-server`
#      (dictation-server feature; butternut's RTX 3050 runs Whisper
#      large-v3-turbo, multilingual), over the cable or the tailnet; kept
#      warm for the session;
#   2. otherwise this machine: Parakeet TDT 0.6B v2 (int8 ONNX, sherpa-onnx)
#      on the CPU for English, a session-only whisper-server with Whisper
#      small (Vulkan iGPU or CPU) for other languages.
# The language follows the active keyboard layout (`layoutLanguages`).
#
# Mic: the one chosen with `dictate input` (or "Dictation drafts" →
# Microphone; kept in ~/<journalDir>/input) when it is connected, else the
# most recently connected Bluetooth headset, else the default source. A
# headset is recorded through WirePlumber's `bluez_input.<MAC>` source, which
# switches it to its headset profile for the session. The panel, the bar
# tooltip and the draft name the mic; a headset sending only silence for 3 s
# (busy with another device, e.g. the phone) raises a notice. No mic at all:
# the press says so (persistent) and records nothing. No speech in the first
# `noSpeechSec` (10 s), or only silence / no audio for that long later: the
# session stops itself with a persistent error.
#
# Drafts: every recording is written to ~/<journalDir>/drafts/<date_time-id>/
# on persistent disk as it happens (raw PCM, fsynced every 2 s and after
# each segment; a power cut loses at most the last 2 s), with meta.json
# (status), the segment transcripts and transcript.txt. A draft is `pending`
# until its text is typed or copied (failed transcription, empty result,
# crash, dead battery: the audio is there); delivered and cancelled drafts
# are compressed to Opus and pruned after `drafts.keepDays`. `dictate
# drafts` lists them, `dictate recover` delivers them, the launcher entry
# "Dictation drafts" does both; pending drafts are announced at login and
# at each session start. Delivered text is also appended to
# ~/<journalDir>/YYYY-MM-DD.md (time + session id).
#
# Feedback (dictation/dictate-overlay.py): a GTK4 layer-shell panel at the
# top right, next to the bar, while a session runs: timer, input level,
# language and backend, the last committed text (stream) or the draft's
# progress (batch), and "Transcribing 3/12 segments" after stop; the timer
# shows the 2 px ink rule at each full minute and turns `warning` past
# `overlay.longSessionMinutes` (a cue, no stop). It never takes keyboard
# focus. The waybar module shows the running mm:ss, refreshed
# by signal once a second during a session only (`warning` past the cue).
# Colours: `surface` paper, `outlineVariant` hairline, `fg`/`fgMuted` text,
# `error` recording dot (as in the bar), `warning` long timer, `accent` for
# the level and the minute rule on `surface` and `surfaceContainer`: all
# pairs in the contrast contract
# (extra/theme-palette.py CONTRACT); sizes from `self.design`.
#
# Battery: no model is resident while idle. The local engine is a
# socket-activated user service: the press itself sends GET /ready (model
# loads while you speak) and it exits after `localIdleSec`.
#
# T3 Code: its transcription runs transcribe.cpp (GGUF) inside the T3
# server of the chosen environment, downloading into its state dir. With
# `t3code.provideModels` the Parakeet GGUF it defaults to is pinned here and
# put where T3 looks for existing copies (the Hugging Face cache layout), so
# T3's "Download" links it offline in a second.
#
# Models are fixed-output fetches pinned by hash: nothing is downloaded at
# dictation time.
{self, ...}: {
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

    # Silero VAD v6.2 (ONNX; the server's GGUF is the same model) for the
    # client-side segmenter. 2.3 MB.
    sileroVad = pkgs.fetchurl {
      name = "silero-vad-v6.2.3.onnx";
      url = "https://github.com/snakers4/silero-vad/raw/v6.2.3/src/silero_vad/data/silero_vad.onnx";
      hash = "sha256-GhU6IvRQnikqlOZ9b5uF6N6yW0mIaCt+F0xlJ52HiOM=";
    };

    d = self.design;
    px = n: "${toString n}px";
    overlayCss = "${config.preferences.theme.stateDir}/current/dictation-overlay.css";

    # The live panel: GTK4 + gtk4-layer-shell through PyGObject. The layer
    # shell library must be loaded before libwayland-client (LD_PRELOAD).
    # The Cairo renderer: a small static panel needs no Vulkan/GL init
    # (faster start, nothing woken on the GPU).
    overlayScript = pkgs.writers.writePython3 "dictate-overlay" {
      libraries = ps: [ps.pygobject3 ps.pycairo];
      flakeIgnore = ["E501"];
    } (builtins.readFile ./dictation/dictate-overlay.py);
    overlay = pkgs.stdenv.mkDerivation {
      name = "dictate-overlay";
      dontUnpack = true;
      nativeBuildInputs = [pkgs.wrapGAppsHook4 pkgs.gobject-introspection];
      buildInputs = [pkgs.gtk4 pkgs.gtk4-layer-shell];
      installPhase = "install -Dm755 ${overlayScript} $out/bin/dictate-overlay";
      preFixup = ''
        gappsWrapperArgs+=(
          --set LD_PRELOAD ${pkgs.gtk4-layer-shell}/lib/libgtk4-layer-shell.so
          --set-default GSK_RENDERER cairo
        )
      '';
      meta.mainProgram = "dictate-overlay";
    };

    # Palette-only stylesheet, rendered per mode into the theme state dir.
    mkOverlayCss = p: ''
      window.dictation {
        background: ${p.surface};
        color: ${p.fg};
        border: ${px d.panel.border} solid ${p.outlineVariant};
        border-radius: ${px d.panel.radius};
        box-shadow: none;
        font-family: "${d.type.family.ui}";
        font-size: ${px d.type.size.body};
      }
      window.dictation .panel {
        padding: ${px d.panel.padding};
        border-spacing: ${px d.panel.gap};
      }
      window.dictation .head { border-spacing: ${px d.space.md}; }
      window.dictation .dot { color: ${p.error}; font-size: ${px d.type.size.caption}; }
      window.dictation .timer {
        font-size: ${px d.type.size.title};
        font-weight: ${toString d.type.weight.medium};
        font-feature-settings: "tnum";
        padding-bottom: ${px d.space.xs};
        border-bottom: ${px d.border.focus} solid ${p.surface};
        transition: border-color ${toString d.motion.base}ms ease-out;
      }
      window.dictation .timer.minute { border-bottom-color: ${p.accent}; }
      window.dictation .timer.long { color: ${p.warning}; }
      window.dictation .dot.finishing, window.dictation .timer.finishing { color: ${p.fgMuted}; }
      window.dictation .meta, window.dictation .status, window.dictation .note {
        color: ${p.fgMuted};
        font-size: ${px d.type.size.caption};
      }
      window.dictation .older { color: ${p.fgMuted}; }
      window.dictation .latest { color: ${p.fg}; }
      window.dictation .older, window.dictation .latest { line-height: ${toString d.type.lineHeight.body}; }
      window.dictation levelbar trough {
        min-height: ${px d.osd.barHeight};
        padding: 0;
        border: none;
        border-radius: ${px d.radius.pill};
        background: ${p.surfaceContainer};
      }
      window.dictation levelbar block {
        min-height: ${px d.osd.barHeight};
        border: none;
        border-radius: ${px d.radius.pill};
      }
      window.dictation levelbar block.filled { background: ${p.accent}; }
      window.dictation levelbar block.empty { background: ${p.surfaceContainer}; }
    '';

    streamConfig = pkgs.writeText "dictate.json" (builtins.toJSON {
      inherit (cfg) servers threads output prompt;
      inherit (cfg) mode;
      keep_days = cfg.drafts.keepDays;
      default_lang = cfg.defaultLanguage;
      local_lang = "en";
      whisper_model = lib.optionalString cfg.localMultilingual "${whisperSmall}";
      append_space = cfg.appendSpace;
      max_sec = cfg.maxSeconds;
      no_speech_sec = cfg.noSpeechSec;
      pause_ms = cfg.pauseMs;
      max_segment_sec = cfg.maxSegmentSec;
      workers = 2;
      waybar_signal = waybarSignal;
      journal_dir = "~/${cfg.journalDir}";
      vad_model = "${sileroVad}";
      overlay = {
        inherit (cfg.overlay) enable;
        css = overlayCss;
        long_session_sec = cfg.overlay.longSessionMinutes * 60;
      };
      bin = {
        pw-record = lib.getExe' pkgs.pipewire "pw-record";
        pw-dump = lib.getExe' pkgs.pipewire "pw-dump";
        swaymsg = lib.getExe' pkgs.sway "swaymsg";
        wl-paste = lib.getExe' pkgs.wl-clipboard "wl-paste";
        wtype = lib.getExe pkgs.wtype;
        wl-copy = lib.getExe' pkgs.wl-clipboard "wl-copy";
        notify-send = lib.getExe' pkgs.libnotify "notify-send";
        systemctl = lib.getExe' pkgs.systemd "systemctl";
        whisper-server = lib.getExe' cfg.localWhisperPackage "whisper-server";
        opusenc = lib.getExe' pkgs.opus-tools "opusenc";
        opusdec = lib.getExe' pkgs.opus-tools "opusdec";
        overlay = "${lib.getExe overlay} --width ${toString d.osd.width} --margin ${toString d.panel.margin}";
      };
    });

    streamScript = pkgs.writers.writePython3 "dictate-stream" {
      libraries = ps: [ps.numpy ps.onnxruntime];
      flakeIgnore = ["E501"];
    } (builtins.readFile ./dictation/dictate-stream.py);
    stream = pkgs.runCommand "dictate-stream" {nativeBuildInputs = [pkgs.makeWrapper];} ''
      makeWrapper ${streamScript} $out/bin/dictate-stream \
        --set-default DICTATE_CONFIG ${streamConfig}
    '';

    preamble = ''
      cfg_servers=${lib.escapeShellArg (lib.concatStringsSep " " cfg.servers)}
      cfg_local_socket="''${XDG_RUNTIME_DIR:?}/dictate/local.sock"
      cfg_stream=${lib.getExe' stream "dictate-stream"}
      cfg_overlay=${
        if cfg.overlay.enable
        then "1"
        else "0"
      }
      cfg_tap_ms=${toString cfg.tapMs}
      cfg_mode="${cfg.mode}"
      cfg_mode_file="$HOME/${cfg.journalDir}/mode"
      cfg_long_sec=${toString (cfg.overlay.longSessionMinutes * 60)}
      cfg_waybar_signal=${toString waybarSignal}
      cfg_caption_px=${toString d.type.size.caption}

      layout_lang() {
        case "$1" in
      ${lib.concatStrings (lib.mapAttrsToList (layout: lang: "  *${lib.escapeShellArg layout}*) echo ${lang} ;;\n") cfg.layoutLanguages)}  *) echo ${cfg.defaultLanguage} ;;
        esac
      }

    '';

    dictate = pkgs.writeShellApplication {
      name = "dictate";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.curl
        pkgs.gawk
        pkgs.jq
        pkgs.libnotify
        pkgs.sway # swaymsg
        pkgs.systemd
        pkgs.util-linux # flock, setsid
      ];
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
          transcribes the session's segments (the local engine takes over if
          it fails mid-session). Empty or none reachable: the local engine.
        '';
      };

      key = lib.mkOption {
        type = lib.types.str;
        default = "Mod4+d";
        description = "Sway key: hold to dictate, tap to latch. `Mod4+Ctrl+<key>` cancels.";
      };

      mode = lib.mkOption {
        type = lib.types.enum ["batch" "stream"];
        default = "batch";
        description = ''
          `batch`: the text is pasted at once, when you stop (segments are still
          transcribed while you speak, so it is quick). `stream`: each
          segment is typed at its pause. `dictate mode toggle` (or
          `modeKey`) switches the next sessions at runtime.
        '';
      };

      modeKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "Mod4+Mod1+d";
        description = "Sway key that switches batch/stream for the next sessions (Mod4+Shift+d is sway reload).";
      };

      drafts.keepDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 7;
        description = ''
          Delivered and cancelled drafts (Opus audio + transcript) are kept
          this long, so a mis-delivered text can still be recovered.
          Undelivered drafts are never pruned.
        '';
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
        description = ''
          whisper.cpp for the local multilingual fallback: its whisper-server
          runs for the session only (Vulkan uses the iGPU; it falls back to
          the CPU).
        '';
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
        description = "Type a space after each dictation session, so consecutive ones don't run together.";
      };

      prompt = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "NixOS, Sway, Claude Code, T3 Code, flake, home-manager.";
        description = ''
          Whisper initial prompt (Whisper backends only): vocabulary and
          style hints. The session's last committed text is appended, so a
          segment continues the previous one's casing and punctuation.
        '';
      };

      maxSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1800;
        description = ''
          Safety stop for a forgotten latch (segments are typed as you go,
          so long sessions are fine; this is not a dictation limit).
        '';
      };

      noSpeechSec = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 10;
        description = ''
          A session that hears no speech in its first this-many seconds, or
          later gets only digital silence (or no audio at all) for that long,
          stops itself with a persistent error notification: a missing,
          muted or wrong mic shows at once, not after minutes. 0 disables.
        '';
      };

      pauseMs = lib.mkOption {
        type = lib.types.ints.between 250 2000;
        default = 550;
        description = ''
          Silence that closes a segment (it is then transcribed and typed).
          Shorter: text appears sooner but sentences split more often.
        '';
      };

      maxSegmentSec = lib.mkOption {
        type = lib.types.ints.between 5 30;
        default = 25;
        description = "Continuous speech is split at its quietest point before this length.";
      };

      journalDir = lib.mkOption {
        type = lib.types.str;
        default = ".local/state/dictation";
        description = "Home-relative directory of the dictation journal (one Markdown file per day).";
      };

      overlay = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Show the live panel (timer, level, backend, running text) while dictating.";
        };
        longSessionMinutes = lib.mkOption {
          type = lib.types.ints.positive;
          default =
            if cfg.mode == "batch"
            then 6
            else 10;
          defaultText = lib.literalExpression ''if mode == "batch" then 6 else 10'';
          description = ''
            Past this, the timer (panel and bar) turns `warning` and the
            panel suggests stopping: a cue, not a limit.
          '';
        };
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

      streamPackage = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        internal = true;
        default = stream;
        description = "The segment-streaming session engine (`dictate-stream`).";
      };

      overlayPackage = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        internal = true;
        default = overlay;
        description = "The live panel (`dictate-overlay`).";
      };
    };

    config = lib.mkMerge [
      {
        home-manager.users.${user} = {
          home.packages = [
            dictate
            # "Dictation drafts" in the launcher: copy / type / retranscribe /
            # discard a draft, switch the mode.
            (pkgs.makeDesktopItem {
              name = "dictation-drafts";
              desktopName = "Dictation drafts";
              genericName = "Recover dictated text";
              comment = "Copy, type, retranscribe or discard a dictation draft; switch batch/stream";
              icon = "audio-input-microphone";
              exec = "${exe} menu";
              categories = ["Utility"];
              keywords = ["dictation" "dictate" "voice" "speech" "transcript" "draft" "recover"];
            })
          ];

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
          # (The mode key goes inside: `mkOptionDefault {…} // {…}` would add
          # it to the override wrapper, not to the bindings.)
          wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault ({
              # HM's default Mod4+d (menu, same as Mod4+space) would override
              # the --no-repeat binding: sway treats them as one binding.
              ${cfg.key} = lib.mkForce null;
              "--no-repeat ${cfg.key}" = "exec ${exe} press";
              "--release ${cfg.key}" = "exec ${exe} release";
              "Mod4+Ctrl+${lib.last (lib.splitString "+" cfg.key)}" = "exec ${exe} cancel";
            }
            // lib.optionalAttrs (cfg.modeKey != null) {
              ${cfg.modeKey} = "exec ${exe} mode toggle";
            });

          # Pending drafts are announced at login; old delivered ones pruned
          # daily (and at each session start).
          systemd.user.services.dictate-drafts = {
            Unit = {
              Description = "Dictation drafts: prune, announce undelivered ones";
              After = ["sway-session.target"];
            };
            Service = {
              Type = "oneshot";
              ExecStart = "${lib.getExe' stream "dictate-stream"} prune --check";
            };
            Install.WantedBy = ["sway-session.target"];
          };
          systemd.user.services.dictate-drafts-prune = {
            Unit.Description = "Dictation drafts: prune delivered drafts";
            Service = {
              Type = "oneshot";
              ExecStart = "${lib.getExe' stream "dictate-stream"} prune";
            };
          };
          systemd.user.timers.dictate-drafts-prune = {
            Unit.Description = "Prune delivered dictation drafts daily";
            Timer = {
              OnCalendar = "daily";
              Persistent = true;
              RandomizedDelaySec = "1h";
            };
            Install.WantedBy = ["timers.target"];
          };

          home.file = lib.mkIf cfg.t3code.provideModels t3ModelFiles;
        };

        # Read at each session start, so no reload hook is needed.
        preferences.theme.files."dictation-overlay.css" = mkOverlayCss;
        persistance.data.directories = [cfg.journalDir];
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
              padding: ${px d.bar.itemPaddingY} 0;
              margin: ${px d.bar.itemMarginY} ${px d.bar.itemMarginX};
              border-radius: ${px d.bar.radius};
            }
            #custom-dictation.recording { color: @error; }
            #custom-dictation.recording.long { color: @warning; }
            #custom-dictation.transcribing { color: @accent; }
          '';
        };
      })
    ];
  };
}
