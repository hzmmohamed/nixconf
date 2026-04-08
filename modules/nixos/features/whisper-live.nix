{self, ...}: {
  flake.nixosModules.whisper-live = {
    config,
    pkgs,
    lib,
    ...
  }: let
    user = config.preferences.user.name;

    whisperLive = self.packages.${pkgs.system}.whisper-live;
    whisperModel = self.packages.${pkgs.system}.whisper-tiny-model;

    # Python with whisper-live and its deps available
    pythonEnv = pkgs.python313.withPackages (ps: [
      whisperLive
      ps.websocket-client
      ps.pyaudio
      ps.fastapi
      ps.uvicorn
    ]);

    # Server wrapper — upstream has no entry point
    whisperLiveServer = pkgs.writeShellScript "whisper-live-server" ''
      exec ${pythonEnv}/bin/python3 -c "
      import sys
      sys.argv = ['whisper-live-server', '--port', '9090', '--backend', 'faster_whisper', '--max_clients', '1']
      from whisper_live.server import TranscriptionServer
      server = TranscriptionServer()
      server.run('0.0.0.0', port=9090, backend='faster_whisper', faster_whisper_custom_model_path='${whisperModel}', max_clients=1, max_connection_time=86400)
      "
    '';

    # Client script wrapped with deps in PATH
    whisperTranscribe = pkgs.writeScriptBin "whisper-transcribe" ''
      #!${pythonEnv}/bin/python3
      ${builtins.readFile ./whisper-live/whisper-transcribe.py}
    '';

    # Waybar status script — reads state files, outputs JSON
    whisperWaybarScript = pkgs.writeShellScript "whisper-waybar" ''
      PIDFILE="$XDG_RUNTIME_DIR/whisper-transcribe.pid"
      MODEFILE="$XDG_RUNTIME_DIR/whisper-transcribe.mode"
      STARTFILE="$XDG_RUNTIME_DIR/whisper-transcribe.start"

      if [ ! -f "$PIDFILE" ] || ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo '{"text": "", "class": "idle"}'
        exit 0
      fi

      MODE=$(cat "$MODEFILE" 2>/dev/null || echo "?")
      START=$(cat "$STARTFILE" 2>/dev/null || echo "0")
      NOW=$(date +%s)
      ELAPSED=$((NOW - ''${START%.*}))
      MIN=$((ELAPSED / 60))
      SEC=$((ELAPSED % 60))
      TIMER=$(printf "%d:%02d" "$MIN" "$SEC")

      echo "{\"text\": \" $TIMER\", \"tooltip\": \"Recording ($MODE)\", \"class\": \"recording\"}"
    '';

    whisperTranscribeWrapped = pkgs.symlinkJoin {
      name = "whisper-transcribe-wrapped";
      paths = [whisperTranscribe];
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = ''
        wrapProgram $out/bin/whisper-transcribe \
          --prefix PATH : ${lib.makeBinPath [
          pkgs.wofi
          pkgs.wtype
          pkgs.wl-clipboard
          pkgs.libnotify
        ]}
      '';
    };
  in {
    home-manager.users.${user} = {
      home.packages = [
        whisperTranscribeWrapped
        pkgs.wtype
      ];

      systemd.user.services.whisper-live-server = {
        Unit = {
          Description = "WhisperLive transcription server";
          After = ["default.target"];
        };
        Service = {
          ExecStart = "${whisperLiveServer}";
          Restart = "on-failure";
          RestartSec = 5;
        };
        Install = {
          WantedBy = ["default.target"];
        };
      };

      programs.waybar.settings.mainBar = {
        "custom/whisper" = {
          exec = "${whisperWaybarScript}";
          return-type = "json";
          interval = 1;
          on-click = "whisper-transcribe";
          tooltip = true;
        };
      };

      programs.waybar.style = lib.mkAfter ''
        #custom-whisper.recording {
          color: #f38ba8;
          font-weight: bold;
        }
        #custom-whisper.idle {
          color: transparent;
          margin: 0;
          padding: 0;
          min-width: 0;
        }
      '';

      wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault {
        "Mod4+Shift+r" = "exec whisper-transcribe";
      };
    };
  };
}
