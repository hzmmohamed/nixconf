#!/usr/bin/env python3
"""Tests for `dictate-stream push` (training lab, plan 2): delivered drafts
go to the lab's inbox as PUTs then POST done, are marked uploaded, and are
not pruned before that (up to unsent_days).

A fake inbox (stdlib http.server) records the requests. Needs numpy and
onnxruntime, as dictate-stream imports them.
"""
import importlib.util
import json
import os
import socket
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "dictate-stream.py"
TMP = tempfile.mkdtemp(prefix="dictate-push-")
CONFIG = {
    "servers": [], "threads": 4, "output": "print", "prompt": "NixOS, Sway.",
    "mode": "batch", "keep_days": 7, "unsent_days": 30, "default_lang": "en",
    "local_lang": "en", "whisper_model": "", "append_space": True, "work_apps": [],
    "max_sec": 600, "no_speech_sec": 10, "pause_ms": 550, "max_segment_sec": 25,
    "workers": 1, "waybar_signal": 8, "journal_dir": os.path.join(TMP, "journal"),
    "vad_model": "", "overlay": {"enable": False, "css": "", "long_session_sec": 600},
    "bin": {}, "lab_url": None,
}
with open(os.path.join(TMP, "dictate.json"), "w") as f:
    json.dump(CONFIG, f)
os.environ["DICTATE_CONFIG"] = os.path.join(TMP, "dictate.json")
os.environ["XDG_RUNTIME_DIR"] = TMP
for k in ("DICTATE_SERVERS", "DICTATE_OUTPUT", "DICTATE_JOURNAL_DIR"):
    os.environ.pop(k, None)

spec = importlib.util.spec_from_file_location("dictate_stream_push", SCRIPT)
ds = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ds)


class FakeInbox:
    def __init__(self, fail_done=False):
        self.requests = []
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def handle_one(self, method):
                n = int(self.headers.get("Content-Length") or 0)
                self.rfile.read(n)
                outer.requests.append((method, self.path, n))
                if method == "POST" and fail_done:
                    self.send_response(500)
                else:
                    self.send_response(204 if method == "PUT" else 200)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def do_PUT(self):
                self.handle_one("PUT")

            def do_POST(self):
                self.handle_one("POST")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self):
        self.server.shutdown()


def make_draft(status="done", age_days=0, **meta):
    d = ds.Draft.create("en", "batch", "mic", journal=True, t0=time.time() - age_days * 86400)
    d.close_audio()
    with open(d.file("audio.pcm"), "wb") as f:
        f.write(b"\0\0" * 1600)
    d.add_commit({"i": 0, "start": 0, "end": 1600, "ok": True, "text": "an invented line",
                  "delivered": True})
    d.save(status=status, complete=True, **meta)
    old = time.time() - age_days * 86400
    os.utime(d.file("meta.json"), (old, old))
    return d


class Push(unittest.TestCase):
    def setUp(self):
        for d in ds.list_drafts():
            d.discard()

    def inbox(self, **kw):
        fake = FakeInbox(**kw)
        self.addCleanup(fake.close)
        return fake

    def test_push_sends_files_then_done_and_marks_uploaded(self):
        fake = self.inbox()
        d = make_draft()
        self.assertTrue(ds.push(d, fake.url))
        origin = socket.gethostname()
        self.assertEqual([(m, p) for m, p, _ in fake.requests], [
            ("PUT", f"/inbox/{origin}/{d.id}/meta.json"),
            ("PUT", f"/inbox/{origin}/{d.id}/commits.jsonl"),
            ("PUT", f"/inbox/{origin}/{d.id}/audio.pcm"),
            ("POST", f"/inbox/{origin}/{d.id}/done"),
        ])
        self.assertEqual(fake.requests[2][2], 3200)
        self.assertTrue(ds.Draft.load(d.path).meta.get("uploaded"))

    def test_push_skips_pending_and_uploaded(self):
        fake = self.inbox()
        self.assertFalse(ds.push(make_draft(status="pending"), fake.url))
        self.assertFalse(ds.push(make_draft(uploaded=123), fake.url))
        self.assertEqual(fake.requests, [])

    def test_push_failure_keeps_draft_unsent(self):
        fake = self.inbox(fail_done=True)
        d = make_draft()
        self.assertFalse(ds.push(d, fake.url))
        self.assertFalse(ds.Draft.load(d.path).meta.get("uploaded"))

    def test_push_keeps_what_compress_wrote_meanwhile(self):
        fake = self.inbox()
        stale = make_draft()
        # The session compresses (and rewrites meta.json) after the timer loaded the draft.
        ds.Draft.load(stale.path).save(duration=5.0, audio={"file": "audio.opus", "format": "opus"})
        self.assertTrue(ds.push(stale, fake.url))
        meta = ds.Draft.load(stale.path).meta
        self.assertEqual(meta["duration"], 5.0)
        self.assertEqual(meta["audio"]["file"], "audio.opus")
        self.assertTrue(meta.get("uploaded"))

    def test_push_unreachable_is_false(self):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        self.assertFalse(ds.push(make_draft(), f"http://127.0.0.1:{port}", timeout=2))

    def test_prune_keeps_unsent_until_unsent_days(self):
        ds.CFG["lab_url"] = "http://127.0.0.1:1"
        self.addCleanup(ds.CFG.__setitem__, "lab_url", None)
        unsent = make_draft(age_days=10)
        sent = make_draft(age_days=10, uploaded=1)
        ancient = make_draft(age_days=31)
        ds.prune()
        left = {d.id for d in ds.list_drafts()}
        self.assertIn(unsent.id, left)
        self.assertNotIn(sent.id, left)
        self.assertNotIn(ancient.id, left)

    def test_prune_without_lab_is_unchanged(self):
        d = make_draft(age_days=10)
        ds.prune()
        self.assertNotIn(d.id, {x.id for x in ds.list_drafts()})


if __name__ == "__main__":
    unittest.main()
