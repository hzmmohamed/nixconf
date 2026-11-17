"""dictate-local: on-demand local speech-to-text engine for `dictate`.

Parakeet TDT 0.6B v2 (int8 ONNX) through sherpa-onnx, on the CPU. Started
by systemd socket activation on the first request (the dictation client
sends GET /ready the moment recording starts, so the model loads while the
user is still speaking), and exits after DICTATE_IDLE_SEC without a
request, which frees its ~1 GB of RAM. The socket stays with systemd.

  GET  /ready       200 "ok" once the model is loaded
  POST /inference   body: a 16-bit PCM WAV file -> {"text": "..."}

Env: DICTATE_PARAKEET (model dir), DICTATE_THREADS, DICTATE_IDLE_SEC.
Run by hand (no socket activation): dictate-local --socket /tmp/x.sock
"""

import http.server
import io
import json
import os
import socket
import sys
import time
import wave

import numpy as np
import sherpa_onnx

MODEL = os.environ["DICTATE_PARAKEET"]
THREADS = int(os.environ.get("DICTATE_THREADS", "4"))
IDLE_SEC = float(os.environ.get("DICTATE_IDLE_SEC", "300"))
RATE = 16000
# Parakeet attends over the whole input: decode long dictations in chunks
# of at most CHUNK_SEC, cut at the quietest 100 ms in the last third.
CHUNK_SEC = 30
MAX_BODY = 300 * RATE * 2 + 4096


def log(msg):
    print(msg, file=sys.stderr, flush=True)


t0 = time.monotonic()
recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
    encoder=f"{MODEL}/encoder.int8.onnx",
    decoder=f"{MODEL}/decoder.int8.onnx",
    joiner=f"{MODEL}/joiner.int8.onnx",
    tokens=f"{MODEL}/tokens.txt",
    num_threads=THREADS,
    model_type="nemo_transducer",
    decoding_method="greedy_search",
)
log(f"model loaded in {time.monotonic() - t0:.2f}s ({THREADS} threads)")


def read_wav(data):
    """16-bit PCM WAV bytes -> float32 mono samples at RATE."""
    with wave.open(io.BytesIO(data)) as w:
        if w.getsampwidth() != 2:
            raise ValueError("expected 16-bit PCM")
        channels, rate = w.getnchannels(), w.getframerate()
        frames = w.readframes(w.getnframes())
    if not frames and len(data) > 44:
        # Header without sizes (recorder killed): take the rest as audio.
        frames = data[44:]
    samples = np.frombuffer(frames[: len(frames) // 2 * 2], dtype=np.int16)
    samples = samples.astype(np.float32) / 32768.0
    if channels > 1:
        samples = samples[: len(samples) // channels * channels]
        samples = samples.reshape(-1, channels).mean(axis=1)
    if rate != RATE:
        n = int(len(samples) * RATE / rate)
        samples = np.interp(
            np.linspace(0, len(samples), n, endpoint=False),
            np.arange(len(samples)),
            samples,
        ).astype(np.float32)
    return samples


def chunks(samples):
    limit = CHUNK_SEC * RATE
    win = RATE // 10
    while len(samples) > limit:
        lo = limit * 2 // 3
        region = samples[lo:limit]
        energy = np.convolve(region * region, np.ones(win), mode="valid")
        cut = lo + int(np.argmin(energy)) + win // 2
        yield samples[:cut]
        samples = samples[cut:]
    yield samples


def transcribe(samples):
    texts = []
    for chunk in chunks(samples):
        if len(chunk) < RATE // 4:
            continue
        stream = recognizer.create_stream()
        stream.accept_waveform(RATE, chunk)
        recognizer.decode_stream(stream)
        texts.append(stream.result.text.strip())
    return " ".join(t for t in texts if t)


class Handler(http.server.BaseHTTPRequestHandler):
    def address_string(self):
        return "local"

    def log_message(self, fmt, *args):
        log(fmt % args)

    def reply(self, code, body, ctype="application/json"):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/ready":
            self.reply(200, "ok\n", "text/plain")
        else:
            self.reply(404, "not found\n", "text/plain")

    def do_POST(self):
        if self.path != "/inference":
            self.reply(404, "not found\n", "text/plain")
            return
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= MAX_BODY:
            self.reply(413, json.dumps({"error": "bad length"}))
            return
        try:
            samples = read_wav(self.rfile.read(length))
            t = time.monotonic()
            text = transcribe(samples)
            log(f"{len(samples) / RATE:.1f}s audio in {time.monotonic() - t:.2f}s")
        except (ValueError, EOFError, wave.Error) as err:
            self.reply(400, json.dumps({"error": str(err)}))
            return
        self.reply(200, json.dumps({"text": text}))


class UnixHTTPServer(http.server.HTTPServer):
    address_family = socket.AF_UNIX
    idle = False

    def server_bind(self):
        socket.socket.bind(self.socket, self.server_address)

    def handle_timeout(self):
        self.idle = True


def main():
    if os.environ.get("LISTEN_FDS") == "1":
        server = UnixHTTPServer("", Handler, bind_and_activate=False)
        server.socket.close()
        server.socket = socket.socket(fileno=3)
    elif len(sys.argv) == 3 and sys.argv[1] == "--socket":
        server = UnixHTTPServer(sys.argv[2], Handler)
    else:
        sys.exit("usage: dictate-local --socket PATH (or socket activation)")

    server.timeout = IDLE_SEC
    while not server.idle:
        server.handle_request()
    log(f"idle for {IDLE_SEC:.0f}s, exiting (model unloaded)")


if __name__ == "__main__":
    main()
