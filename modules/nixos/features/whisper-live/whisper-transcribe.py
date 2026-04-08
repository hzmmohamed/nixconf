#!/usr/bin/env python3
"""
whisper-transcribe: Live transcription with output to clipboard or typed input.

Hotkey toggles a wofi menu:
  - If no session: choose "Clipboard" or "Type into window" to start
  - If session active: choose "Stop recording" to end

State files in XDG_RUNTIME_DIR:
  - whisper-transcribe.pid   — PID of recording process
  - whisper-transcribe.mode  — "clipboard" or "type"
  - whisper-transcribe.start — epoch timestamp of recording start

Waybar reads these to show a recording indicator.
"""
import os
import sys
import signal
import subprocess
import threading
import time

RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
PIDFILE = os.path.join(RUNTIME_DIR, "whisper-transcribe.pid")
MODEFILE = os.path.join(RUNTIME_DIR, "whisper-transcribe.mode")
STARTFILE = os.path.join(RUNTIME_DIR, "whisper-transcribe.start")
HOST = "localhost"
PORT = 9090


def notify(msg, timeout=3000):
    subprocess.run(
        ["notify-send", "-t", str(timeout), "WhisperLive", msg], check=False
    )


def is_server_running():
    import websocket

    try:
        ws = websocket.create_connection(f"ws://{HOST}:{PORT}", timeout=2)
        ws.close()
        return True
    except Exception:
        return False


def stop_session():
    try:
        with open(PIDFILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, signal.SIGTERM)
    except (FileNotFoundError, ProcessLookupError, ValueError):
        pass
    finally:
        cleanup_state_files()


def cleanup_state_files():
    for f in (PIDFILE, MODEFILE, STARTFILE):
        try:
            os.unlink(f)
        except FileNotFoundError:
            pass


def is_session_active():
    if not os.path.exists(PIDFILE):
        return False
    try:
        with open(PIDFILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return True
    except (FileNotFoundError, ProcessLookupError, ValueError):
        cleanup_state_files()
        return False


def show_menu_start():
    options = "Clipboard\nType into window"
    try:
        result = subprocess.run(
            ["wofi", "--dmenu", "--prompt", "Start transcription"],
            input=options,
            capture_output=True,
            text=True,
            timeout=30,
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


def show_menu_stop():
    try:
        mode = ""
        try:
            with open(MODEFILE) as f:
                mode = f.read().strip()
        except FileNotFoundError:
            pass
        label = f"Stop recording ({mode})" if mode else "Stop recording"
        result = subprocess.run(
            ["wofi", "--dmenu", "--prompt", "Recording active"],
            input=label,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            return False
        return result.stdout.strip().startswith("Stop")
    except subprocess.TimeoutExpired:
        return False


def format_elapsed(seconds):
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    if h:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m}:{s:02d}"


def run_transcription(mode):
    start_time = time.time()

    with open(PIDFILE, "w") as f:
        f.write(str(os.getpid()))
    with open(MODEFILE, "w") as f:
        f.write(mode)
    with open(STARTFILE, "w") as f:
        f.write(str(start_time))

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
            accumulated_text.clear()
            accumulated_text.append(text.strip())
        elif mode == "type":
            new_text = text[len(last_text) :]
            if new_text.strip():
                subprocess.run(["wtype", "--", new_text], check=False)
            last_text = text

    mode_label = "clipboard" if mode == "clipboard" else "type-into-window"
    notify(f"Recording started ({mode_label})")

    try:
        client = TranscriptionClient(
            host=HOST,
            port=PORT,
            lang=None,
            model="tiny",
            use_vad=True,
            transcription_callback=on_transcription,
        )
        client_thread = threading.Thread(target=client, daemon=True)
        client_thread.start()

        while running and client_thread.is_alive():
            time.sleep(0.1)

    except Exception as e:
        notify(f"Transcription error: {e}")
    finally:
        running = False
        elapsed = time.time() - start_time

        if mode == "clipboard" and accumulated_text:
            full_text = accumulated_text[-1]
            subprocess.run(["wl-copy", "--", full_text], check=False)
            notify(
                f"Copied to clipboard ({len(full_text)} chars, {format_elapsed(elapsed)})",
                timeout=5000,
            )
        elif mode == "clipboard":
            notify("No text transcribed", timeout=3000)
        else:
            notify(f"Done typing ({format_elapsed(elapsed)})", timeout=3000)

        cleanup_state_files()


def main():
    if is_session_active():
        if show_menu_stop():
            stop_session()
        sys.exit(0)

    if not is_server_running():
        notify("WhisperLive server not running")
        sys.exit(1)

    mode = show_menu_start()
    if mode is None:
        sys.exit(0)

    run_transcription(mode)


if __name__ == "__main__":
    main()
