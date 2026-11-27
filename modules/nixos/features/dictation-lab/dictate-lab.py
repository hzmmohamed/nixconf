"""dictate-lab: the dictation training lab's hub (dictation-lab feature).

Every delivered draft (Pollen on the phone, `dictate` on the laptops) is
uploaded here and normalized into one tree, so the later stages (suspects,
the correction game, vocabulary/rules, a dataset) read one schema:

  <data>/drafts/<origin>/<id>/meta.json       id, origin, created_ms, lang,
                                              tier, app, prompt_sha, engine,
                                              text, duration, received_ms,
                                              source
                              segments.jsonl  i, start, end (samples, 16 kHz),
                                              text, ok, conf?
                              audio.opus      24 kb/s speech
                              source/         the uploaded files but audio

  dictate-lab serve --data-dir D --port P [--host H]
      PUT  /inbox/<origin>/<id>/<file>   meta.json, segments.jsonl (phone),
                                         commits.jsonl (laptop), audio.wav |
                                         audio.pcm (s16le 16 kHz) | audio.opus
      POST /inbox/<origin>/<id>/done     normalize, replace any earlier copy
      GET  /health
  dictate-lab prune --data-dir D --audio-days N [--keep-lang ar ...]
      drop full audio older than N days (text and segments stay)

Only loopback and the user's own untagged tailnet devices get in
(`tailscale whois`); anything else, or a whois that fails, gets 403 before
a byte is written. Transcript text is never logged. Python stdlib only.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

RATE = 16000
MAX_BODY = 256 * 1024 * 1024
ORIGIN = re.compile(r"^[a-z0-9-]{1,32}$")
IDENT = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
FILES = ("meta.json", "segments.jsonl", "commits.jsonl", "audio.wav", "audio.pcm", "audio.opus")
AUDIO = ("audio.opus", "audio.wav", "audio.pcm")
CONF_KEYS = {"avgLogprob": "avg_logprob", "noSpeechProb": "no_speech_prob", "langP": "lang_p"}


def log(msg):
    print(f"dictate-lab: {msg}", file=sys.stderr, flush=True)


def valid(origin, ident):
    return bool(ORIGIN.match(origin) and IDENT.match(ident) and ident not in (".", ".."))


# --- normalization ------------------------------------------------------------
def _jsonl(data):
    out = []
    for line in (data or b"").decode().splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            pass  # a line torn by a kill: skip it
    return out


def _conf(conf):
    if not isinstance(conf, dict):
        return None
    return {CONF_KEYS.get(k, k): v for k, v in conf.items()}


def _segment(s):
    seg = {"i": s.get("i"), "start": s.get("start"), "end": s.get("end"),
           "text": s.get("text", ""), "ok": s.get("ok", True)}
    conf = _conf(s.get("conf"))
    if conf is not None:
        seg["conf"] = conf
    return seg


def normalize(origin, src):
    """The uploaded files -> (meta, segments) in the lab's schema. Phone
    drafts carry segments.jsonl and camelCase keys; laptop drafts carry
    commits.jsonl and the dictate-stream meta. A tier other than exactly
    "work" is personal (fail closed)."""
    m = json.loads(src["meta.json"])
    if not isinstance(m, dict):
        raise ValueError("meta.json is not an object")
    if "commits.jsonl" in src or "t0" in m:
        segments = [_segment(c) for c in _jsonl(src.get("commits.jsonl"))]
        meta = {"created_ms": int(float(m.get("t0", 0)) * 1000), "lang": m.get("lang"),
                "engine": m.get("backend"), "prompt_sha": m.get("prompt_sha"),
                "text": " ".join(s["text"] for s in segments if s["ok"] and s["text"]),
                "duration": m.get("duration")}
    else:
        segments = [_segment(s) for s in _jsonl(src.get("segments.jsonl"))]
        meta = {"created_ms": m.get("createdMs"), "lang": m.get("language"),
                "engine": m.get("engine"), "prompt_sha": m.get("promptSha"),
                "text": m.get("text") or " ".join(s["text"] for s in segments if s["text"]),
                "duration": None}
    meta.update(id=m.get("id"), origin=origin, app=m.get("app") or None,
                tier="work" if m.get("tier") == "work" else "personal")
    return meta, segments


def to_opus(name, data, dest):
    """Write the draft's audio as Opus at dest (24 kb/s speech)."""
    if name == "audio.opus":
        dest.write_bytes(data)
        return
    if name == "audio.wav":
        args = []
    elif name == "audio.pcm":
        args = ["--raw", "--raw-bits", "16", "--raw-rate", str(RATE), "--raw-chan", "1"]
    else:
        raise ValueError(f"not audio: {name}")
    subprocess.run(["opusenc", "--quiet", *args, "--bitrate", "24", "--speech", "-", str(dest)],
                   input=data, check=True, timeout=600)


# --- peers --------------------------------------------------------------------
class PeerCheck:
    """Loopback, or a tailnet node of the same user without tags."""

    def __init__(self, whois, self_user, allow_loopback=True, ttl=300):
        self.whois = whois
        self.self_user = self_user
        self.allow_loopback = allow_loopback
        self.ttl = ttl
        self.cache = {}
        self.lock = threading.Lock()

    def _check(self, ip):
        try:
            w = self.whois(ip)
        except Exception as err:
            log(f"whois {ip}: {err}")
            return False
        if not isinstance(w, dict):
            return False
        user = (w.get("UserProfile") or {}).get("ID")
        tags = (w.get("Node") or {}).get("Tags")
        return user is not None and user == self.self_user and not tags

    def allowed(self, ip):
        if self.allow_loopback and ip in ("127.0.0.1", "::1"):
            return True
        now = time.monotonic()
        with self.lock:
            hit = self.cache.get(ip)
            if hit and now - hit[1] < self.ttl:
                return hit[0]
        ok = self._check(ip)
        with self.lock:
            self.cache[ip] = (ok, now)
        return ok


def tailscale_whois(ip):
    out = subprocess.run(["tailscale", "whois", "--json", ip], capture_output=True, timeout=5)
    return json.loads(out.stdout) if out.returncode == 0 else None


def tailscale_self_user():
    out = subprocess.run(["tailscale", "status", "--json"], capture_output=True, timeout=10, check=True)
    return json.loads(out.stdout)["Self"]["UserID"]


# --- server -------------------------------------------------------------------
def _replace_dir(tmp, target):
    old = None
    if target.exists():
        old = target.with_name(target.name + ".old")
        if old.exists():
            shutil.rmtree(old)
        os.replace(target, old)
    os.replace(tmp, target)
    if old:
        shutil.rmtree(old)


_locks = {}
_locks_lock = threading.Lock()


def _draft_lock(origin, ident):
    with _locks_lock:
        return _locks.setdefault((origin, ident), threading.Lock())


def finish(data_dir, origin, ident):
    """POST done: incoming/<origin>/<id> -> drafts/<origin>/<id>, normalized.
    One at a time per draft: two uploads of the same draft (a laptop's own
    push and its hourly retry) must not share the .tmp dir."""
    with _draft_lock(origin, ident):
        return _finish(data_dir, origin, ident)


def _finish(data_dir, origin, ident):
    inc = data_dir / "incoming" / origin / ident
    src = {p.name: p.read_bytes() for p in inc.iterdir() if p.name in FILES} if inc.is_dir() else {}
    audio = next((a for a in AUDIO if a in src), None)
    if "meta.json" not in src or audio is None:
        raise ValueError("needs meta.json and audio")
    meta, segments = normalize(origin, src)
    meta["id"] = ident
    meta["received_ms"] = int(time.time() * 1000)
    meta["source"] = sorted(src)
    drafts = data_dir / "drafts" / origin
    drafts.mkdir(parents=True, exist_ok=True)
    tmp = drafts / (ident + ".tmp")
    if tmp.exists():
        shutil.rmtree(tmp)
    (tmp / "source").mkdir(parents=True)
    for name, data in src.items():
        if name not in AUDIO:
            (tmp / "source" / name).write_bytes(data)
    to_opus(audio, src[audio], tmp / "audio.opus")
    (tmp / "segments.jsonl").write_text("".join(json.dumps(s, ensure_ascii=False) + "\n" for s in segments))
    (tmp / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1) + "\n")
    _replace_dir(tmp, drafts / ident)
    shutil.rmtree(inc)
    return meta


def make_server(data_dir, port, peers, host="0.0.0.0"):
    data_dir = Path(data_dir)

    class Handler(BaseHTTPRequestHandler):
        server_version = "dictate-lab"

        def log_message(self, fmt, *args):  # no request lines (paths carry ids only, but keep it quiet)
            pass

        def reply(self, code, body=None):
            data = json.dumps(body).encode() if body is not None else b""
            self.send_response(code)
            if data:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def route(self):
            if not peers.allowed(self.client_address[0]):
                self.reply(403, {"error": "not one of your devices"})
                return None
            parts = self.path.split("?")[0].strip("/").split("/")
            if len(parts) != 4 or parts[0] != "inbox":
                self.reply(404, {"error": "no such route"})
                return None
            _, origin, ident, name = parts
            if not valid(origin, ident):
                self.reply(400, {"error": "bad origin or id"})
                return None
            return origin, ident, name

        def do_GET(self):
            if self.path == "/health":
                self.reply(200, {"ok": True})
            else:
                self.reply(404, {"error": "no such route"})

        def do_PUT(self):
            r = self.route()
            if not r:
                return
            origin, ident, name = r
            if name not in FILES:
                self.reply(400, {"error": "unknown file"})
                return
            length = self.headers.get("Content-Length")
            if length is None:
                self.reply(411, {"error": "Content-Length required"})
                return
            length = int(length)
            if length > MAX_BODY:
                self.reply(413, {"error": "too large"})
                return
            inc = data_dir / "incoming" / origin / ident
            inc.mkdir(parents=True, exist_ok=True)
            part = inc / (name + ".part")
            with open(part, "wb") as f:
                left = length
                while left:
                    chunk = self.rfile.read(min(left, 1 << 20))
                    if not chunk:
                        break
                    f.write(chunk)
                    left -= len(chunk)
            if left:
                part.unlink(missing_ok=True)
                self.reply(400, {"error": "body cut short"})
                return
            os.replace(part, inc / name)
            self.reply(204)

        def do_POST(self):
            r = self.route()
            if not r:
                return
            origin, ident, name = r
            if name != "done":
                self.reply(404, {"error": "no such route"})
                return
            try:
                meta = finish(data_dir, origin, ident)
            except (ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError, OSError) as err:
                log(f"{origin}/{ident}: rejected ({type(err).__name__})")
                self.reply(400, {"error": str(err) if isinstance(err, ValueError) else type(err).__name__})
                return
            log(f"{origin}/{ident}: stored ({meta['tier']}, {len(meta.get('text') or '')} chars)")
            self.reply(200, {"ok": True, "id": ident})

    return ThreadingHTTPServer((host, port), Handler)


# --- retention ----------------------------------------------------------------
def prune(data_dir, audio_days, keep_lang, now_ms):
    """Delete audio.opus of drafts received more than audio_days ago, unless
    their language is in keep_lang. Text and segments stay."""
    cutoff = now_ms - audio_days * 86_400_000
    removed = 0
    for meta_file in Path(data_dir).glob("drafts/*/*/meta.json"):
        try:
            meta = json.loads(meta_file.read_text())
        except (OSError, ValueError):
            continue
        audio = meta_file.parent / "audio.opus"
        if audio.exists() and meta.get("received_ms", now_ms) < cutoff and meta.get("lang") not in keep_lang:
            audio.unlink()
            removed += 1
    return removed


def main():
    ap = argparse.ArgumentParser(prog="dictate-lab")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--data-dir", required=True, type=Path)
    s.add_argument("--port", type=int, default=8181)
    s.add_argument("--host", default="0.0.0.0")
    p = sub.add_parser("prune")
    p.add_argument("--data-dir", required=True, type=Path)
    p.add_argument("--audio-days", type=int, default=90)
    p.add_argument("--keep-lang", nargs="*", default=["ar"])
    args = ap.parse_args()
    if args.cmd == "serve":
        args.data_dir.mkdir(parents=True, exist_ok=True)
        server = make_server(args.data_dir, args.port, PeerCheck(tailscale_whois, tailscale_self_user()),
                             host=args.host)
        log(f"serving on {args.host}:{args.port}, data in {args.data_dir}")
        server.serve_forever()
    else:
        n = prune(args.data_dir, args.audio_days, args.keep_lang, int(time.time() * 1000))
        log(f"pruned the audio of {n} drafts")


if __name__ == "__main__":
    main()
