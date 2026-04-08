# WhisperLive Local Transcription — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Package WhisperLive as a NixOS feature module with a systemd server and hotkey-triggered transcription to clipboard or live-typing.

**Architecture:** WhisperLive server runs as a systemd user service on localhost:9090 using faster_whisper backend with the tiny model. A toggle script shows a wofi menu to choose output mode, starts/stops a Python client that streams mic audio and routes transcribed text.

**Tech Stack:** Python 3.13, faster-whisper, websockets, PyAudio, wtype, wl-clipboard, wofi

---

### Task 1: Package whisper-live as a flake-parts perSystem package

**Files:**
- Create: `modules/packages/whisper-live.nix`

**Step 1: Create the whisper-live package**

This is a Python package built from GitHub source. We only need the `faster_whisper` backend dependencies — skip torch/openvino/onnxruntime (faster-whisper bundles ctranslate2 which handles inference). Relax strict version pins.

```nix
{...}: {
  perSystem = {
    pkgs,
    lib,
    ...
  }: let
    python3Packages = pkgs.python313Packages;

    whisperLiveSrc = pkgs.fetchFromGitHub {
      owner = "collabora";
      repo = "WhisperLive";
      rev = "v0.8.0";
      hash = ""; # will be filled after first build attempt
    };
  in {
    packages.whisper-live = python3Packages.buildPythonApplication {
      pname = "whisper-live";
      version = "0.8.0";
      pyproject = false;
      format = "setuptools";

      src = whisperLiveSrc;

      propagatedBuildInputs = with python3Packages; [
        faster-whisper
        websockets
        websocket-client
        pyaudio
        scipy
        soundfile
        numpy
        numba
        librosa
      ];

      # Relax strict version pins from upstream
      pythonRelaxDeps = [
        "numpy"
        "faster-whisper"
        "onnxruntime"
        "tokenizers"
      ];

      # Remove deps we don't need (openvino, torch, onnxruntime)
      postPatch = ''
        sed -i '/openvino/d' setup.py
        sed -i '/torch/d' setup.py
        sed -i '/torchaudio/d' setup.py
        sed -i '/onnxruntime/d' setup.py
        sed -i '/openai-whisper/d' setup.py
        sed -i '/kaldialign/d' setup.py
        sed -i '/optimum/d' setup.py
        sed -i '/tokenizers/d' setup.py
      '';

      doCheck = false;

      meta = {
        description = "A nearly-live implementation of OpenAI's Whisper";
        homepage = "https://github.com/collabora/WhisperLive";
        license = lib.licenses.mit;
        mainProgram = "whisper-live";
        platforms = lib.platforms.linux;
      };
    };
  };
}
```

**Step 2: Get the source hash**

Run: `nix-prefetch-github collabora WhisperLive --rev v0.8.0`

If v0.8.0 tag doesn't exist, check latest tag or use main branch commit hash. Update the hash in the file.

**Step 3: Try to build**

Run: `nix build .#whisper-live`

Fix any missing dependencies or import errors iteratively. The goal is a package that provides the `whisper_live` Python module and the server/client scripts.

**Step 4: Commit**

```bash
git add modules/packages/whisper-live.nix
git commit -m "feat: package whisper-live for NixOS"
```

---

### Task 2: Create the whisper-transcribe client script

**Files:**
- Create: `modules/nixos/features/whisper-live/whisper-transcribe.py`

**Step 1: Write the client script**

This Python script handles:
- PID file toggle (start/stop)
- Wofi menu for mode selection
- Connecting to the WhisperLive server
- Routing output to clipboard or wtype

```python
#!/usr/bin/env python3
"""
whisper-transcribe: Toggle live transcription with output to clipboard or typed input.

Usage: whisper-transcribe
  - First call: shows wofi menu, starts transcription
  - Second call: stops transcription, delivers result
"""
import os
import sys
import signal
import subprocess
import json
import threading
import time

PIDFILE = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "whisper-transcribe.pid")
HOST = "localhost"
PORT = 9090

def notify(msg):
    subprocess.run(["notify-send", "-t", "3000", "WhisperLive", msg])

def is_server_running():
    """Check if whisper-live server is accepting connections."""
    import websocket
    try:
        ws = websocket.create_connection(f"ws://{HOST}:{PORT}", timeout=2)
        ws.close()
        return True
    except Exception:
        return False

def stop_session():
    """Kill running transcription session."""
    try:
        with open(PIDFILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, signal.SIGTERM)
    except (FileNotFoundError, ProcessLookupError, ValueError):
        pass
    finally:
        try:
            os.unlink(PIDFILE)
        except FileNotFoundError:
            pass

def show_menu():
    """Show wofi menu and return selected mode."""
    options = "Clipboard\nType into window"
    try:
        result = subprocess.run(
            ["wofi", "--dmenu", "--prompt", "Transcription mode"],
            input=options, capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return None
        choice = result.stdout.strip()
        if choice == "Clipboard":
            return "clipboard"
        elif choice == "Type into window":
            return "type"
        return None
    except subprocess.TimeoutExpired:
        return None

def run_transcription(mode):
    """Run transcription client in the selected mode."""
    # Write PID file
    with open(PIDFILE, "w") as f:
        f.write(str(os.getpid()))

    accumulated_text = []
    last_text = ""
    running = True

    def handle_stop(signum, frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)

    from whisper_live.client import TranscriptionClient

    def on_transcription(text, segments):
        nonlocal last_text
        if not text or not text.strip():
            return

        if mode == "clipboard":
            # Store latest full transcription (server sends cumulative text)
            accumulated_text.clear()
            accumulated_text.append(text.strip())
        elif mode == "type":
            # Type only the new portion
            new_text = text[len(last_text):]
            if new_text.strip():
                subprocess.run(["wtype", "--", new_text], check=False)
            last_text = text

    try:
        client = TranscriptionClient(
            host=HOST,
            port=PORT,
            lang=None,  # auto-detect (supports English and Arabic)
            model="tiny",
            use_vad=True,
            transcription_callback=on_transcription,
        )
        # Start microphone recording in background
        client_thread = threading.Thread(target=client, daemon=True)
        client_thread.start()

        notify("Transcribing...")

        while running and client_thread.is_alive():
            time.sleep(0.1)

    except Exception as e:
        notify(f"Transcription error: {e}")
    finally:
        if mode == "clipboard" and accumulated_text:
            full_text = accumulated_text[-1]
            subprocess.run(["wl-copy", "--", full_text], check=False)
            notify(f"Copied to clipboard ({len(full_text)} chars)")
        elif mode == "clipboard":
            notify("No text transcribed")

        try:
            os.unlink(PIDFILE)
        except FileNotFoundError:
            pass

def main():
    # Toggle: if session running, stop it
    if os.path.exists(PIDFILE):
        stop_session()
        sys.exit(0)

    # Check server
    if not is_server_running():
        notify("WhisperLive server not running")
        sys.exit(1)

    # Show menu
    mode = show_menu()
    if mode is None:
        sys.exit(0)

    run_transcription(mode)

if __name__ == "__main__":
    main()
```

**Step 2: Commit**

```bash
git add modules/nixos/features/whisper-live/whisper-transcribe.py
git commit -m "feat: add whisper-transcribe client script"
```

---

### Task 3: Create the NixOS feature module

**Files:**
- Create: `modules/nixos/features/whisper-live.nix`

**Step 1: Write the module**

The module needs to:
- Import whisper-live package
- Set up server as systemd user service
- Wrap the client script with all deps in PATH
- Add sway keybinding

```nix
{self, ...}: {
  flake.nixosModules.whisper-live = {
    config,
    pkgs,
    lib,
    ...
  }: let
    user = config.preferences.user.name;

    whisperLive = self.packages.${pkgs.system}.whisper-live;

    whisperTranscribe = pkgs.writeScriptBin "whisper-transcribe" ''
      #!${whisperLive.python}/bin/python3
      ${builtins.readFile ./whisper-live/whisper-transcribe.py}
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
          ]} \
          --prefix PYTHONPATH : "${whisperLive}/${whisperLive.python.sitePackages}"
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
          ExecStart = "${whisperLive}/bin/run_server.py --port 9090 --backend faster_whisper --max_clients 1";
          Restart = "on-failure";
          RestartSec = 5;
        };
        Install = {
          WantedBy = ["default.target"];
        };
      };

      wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault {
        "Mod4+Shift+t" = "exec whisper-transcribe";
      };
    };
  };
}
```

Note: The exact ExecStart path and Python interpreter details will depend on how the whisper-live package exposes its server script. Adjust during implementation.

**Step 2: Verify evaluation**

Run: `nix eval .#nixosConfigurations.butternut.config.home-manager.users.hfahmi.systemd.user.services.whisper-live-server.Unit.Description --json`

Expected: `"WhisperLive transcription server"`

**Step 3: Commit**

```bash
git add modules/nixos/features/whisper-live.nix modules/nixos/features/whisper-live/
git commit -m "feat: add whisper-live NixOS module with server and hotkey"
```

---

### Task 4: Add to butternut host config

**Files:**
- Modify: `modules/nixos/hosts/butternut/configuration.nix`

**Step 1: Add the import**

Add `self.nixosModules.whisper-live` to the imports list in butternut's configuration, near the other feature modules.

**Step 2: Check for keybinding conflicts**

The design uses `Mod4+Shift+t`. Check butternut's configuration.nix for existing use of this binding. If it conflicts (e.g., darkman toggle uses `Mod4+Shift+t`), pick an alternative like `Mod4+Shift+r` (for "record").

**Step 3: Verify full build**

Run: `nix build .#nixosConfigurations.butternut.config.system.build.toplevel --no-link`

Fix any build errors.

**Step 4: Commit**

```bash
git add modules/nixos/hosts/butternut/configuration.nix
git commit -m "feat: enable whisper-live on butternut"
```

---

### Task 5: Test and iterate

**Step 1: Deploy**

Run: `doas nixos-rebuild switch --flake .`

**Step 2: Verify server starts**

Run: `systemctl --user status whisper-live-server`

The server will download the `tiny` model on first run — this may take a minute.

**Step 3: Test transcription**

Press `Mod4+Shift+t`, select "Clipboard", speak, press `Mod4+Shift+t` again. Check clipboard with `wl-paste`.

**Step 4: Fix issues**

Common problems to watch for:
- PyAudio needs `portaudio` available at runtime — may need `LD_LIBRARY_PATH` or `buildInputs`
- The server's `run_server.py` may not be installed as a bin script — may need a custom wrapper
- The `TranscriptionClient` API may differ from docs — check actual imports work

**Step 5: Commit fixes**

```bash
git add -u
git commit -m "fix: whisper-live runtime adjustments"
```
