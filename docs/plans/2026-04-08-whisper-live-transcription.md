# WhisperLive Local Transcription Service

## Overview

Local real-time speech-to-text on butternut using [WhisperLive](https://github.com/collabora/WhisperLive). A systemd user service runs the transcription server, and a sway hotkey triggers a wofi menu to choose between clipboard or live-typing output modes.

## Architecture

- **Server**: WhisperLive with `faster_whisper` backend, `tiny` model, listening on `localhost:9090`
- **Client**: Python script connecting to the server, streaming mic audio
- **Output**: Two modes selected via wofi menu
- **Languages**: English and Arabic

## Components

### 1. Python environment

`python3.withPackages` including `whisper-live` and dependencies (faster-whisper, websockets, pyaudio, etc.).

### 2. Systemd user service (`whisper-live-server`)

- Runs on login (`wantedBy = ["default.target"]`)
- `ExecStart` = server with `--port 9090 --backend faster_whisper --max_clients 1`
- Auto-restarts on failure

### 3. Transcription script (`whisper-transcribe`)

Toggle behavior via PID file at `$XDG_RUNTIME_DIR/whisper-transcribe.pid`:

- **No active session**: Show wofi menu with "Clipboard" / "Type into window", start client in selected mode
- **Active session**: Kill client, clean up PID file

#### Clipboard mode
- Accumulate transcribed text segments in memory
- On stop: pipe full text to `wl-copy`, show `notify-send` confirmation

#### Type-into-window mode
- As segments arrive, immediately send to focused window via `wtype`
- On stop: disconnect cleanly

### 4. Sway keybinding

`Mod4+Shift+v` bound to `exec whisper-transcribe`

### 5. Dependencies

- `wtype` (Wayland keyboard input simulation)
- `wl-clipboard` (clipboard access)
- `wofi` (menu — already available from desktop module)
- `libnotify` (notify-send — already available)

## NixOS module

Single file: `modules/nixos/features/whisper-live.nix`

- Firewall: no ports needed (localhost only)
- All packages scoped to user via home-manager
- Server runs as user service (needs mic access)

## Error handling

- Server not running: notification "WhisperLive server not running"
- Wofi dismissed: no action
- Server crash: systemd auto-restarts
