#!/usr/bin/env python3
"""Tests for dictate-lab's inbox (training lab, plan 2): phone and laptop
drafts arrive by PUT, are normalized on POST done, and only the user's own
devices get in. Needs opusenc (opus-tools) on PATH.

Run: python3 -m unittest discover -s <this dir> -v
"""
import http.client
import importlib.util
import io
import json
import tempfile
import threading
import unittest
import wave
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "dictate-lab.py"
spec = importlib.util.spec_from_file_location("dictate_lab", SCRIPT)
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)

ME = 7


def silent_wav(seconds=0.5):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b"\0\0" * int(16000 * seconds))
    return buf.getvalue()


# Invented text only (public repo).
PHONE_META = {"status": "delivered", "createdMs": 1700000000000, "updatedMs": 1,
              "language": "en", "engine": "http://x:8178", "text": "an invented line",
              "tier": "work", "app": "com.example.agent", "promptSha": "abc123def456",
              "origin": "phone"}
PHONE_SEG = {"i": 0, "start": 0, "end": 8000, "text": "an invented line", "engine": "http://x:8178",
             "conf": {"avgLogprob": -0.3, "noSpeechProb": 0.01,
                      "words": [{"w": " an", "p": 0.9, "start": 0.0, "end": 0.2}],
                      "lang": "english", "langP": 0.98}}
LAPTOP_META = {"id": "2026-11-25_120000-abcd", "sid": "abcd", "t0": 1700000100, "lang": "en",
               "backend": "butternut GPU", "tier": "personal", "app": "kitty",
               "prompt_sha": "0123456789ab", "duration": 0.5, "status": "done"}
LAPTOP_COMMITS = [
    {"i": 0, "start": 0, "end": 4000, "ok": True, "text": "first part", "delivered": True},
    {"i": 1, "start": 4000, "end": 6000, "ok": False, "text": "", "delivered": False},
    {"i": 2, "start": 6000, "end": 8000, "ok": True, "text": "second part", "delivered": True,
     "conf": {"avg_logprob": -0.2, "no_speech_prob": 0.0, "words": [], "lang": "english", "lang_p": 0.9}},
]


class Inbox(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="lab-test-"))
        self.data = self.root / "data"
        self.whois = {}
        self.server = self.start(lab.PeerCheck(lambda ip: self.whois.get(ip), ME))

    def start(self, peers):
        server = lab.make_server(self.data, 0, peers, host="127.0.0.1")
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        return server

    def req(self, method, path, body=None, server=None, headers=None):
        port = (server or self.server).server_address[1]
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
        c.request(method, path, body=body, headers=headers or {})
        r = c.getresponse()
        data = r.read()
        c.close()
        return r.status, data

    def upload(self, origin, ident, files, server=None):
        for name, data in files.items():
            status, _ = self.req("PUT", f"/inbox/{origin}/{ident}/{name}", data, server)
            self.assertEqual(status, 204, name)
        return self.req("POST", f"/inbox/{origin}/{ident}/done", b"", server)

    def phone_files(self, **meta):
        return {"meta.json": json.dumps(dict(PHONE_META, **meta)).encode(),
                "segments.jsonl": (json.dumps(PHONE_SEG) + "\n").encode(),
                "audio.wav": silent_wav()}

    def draft(self, origin, ident):
        d = self.data / "drafts" / origin / ident
        meta = json.loads((d / "meta.json").read_text())
        segs = [json.loads(x) for x in (d / "segments.jsonl").read_text().splitlines()]
        return d, meta, segs

    def test_health(self):
        self.assertEqual(self.req("GET", "/health"), (200, b'{"ok": true}'))

    def test_phone_draft_normalizes(self):
        status, _ = self.upload("phone", "20261125_120000-0a1b", self.phone_files())
        self.assertEqual(status, 200)
        d, meta, segs = self.draft("phone", "20261125_120000-0a1b")
        self.assertEqual(meta["tier"], "work")
        self.assertEqual(meta["lang"], "en")
        self.assertEqual(meta["created_ms"], 1700000000000)
        self.assertEqual(meta["prompt_sha"], "abc123def456")
        self.assertEqual(meta["origin"], "phone")
        self.assertEqual(meta["app"], "com.example.agent")
        self.assertEqual(meta["text"], "an invented line")
        self.assertEqual(segs[0]["conf"]["avg_logprob"], -0.3)
        self.assertEqual(segs[0]["conf"]["no_speech_prob"], 0.01)
        self.assertEqual(segs[0]["conf"]["lang_p"], 0.98)
        self.assertTrue(segs[0]["ok"])
        self.assertTrue((d / "audio.opus").stat().st_size > 0)
        self.assertTrue((d / "source" / "meta.json").exists())
        self.assertFalse((self.data / "incoming" / "phone" / "20261125_120000-0a1b").exists())

    def test_laptop_draft_normalizes(self):
        files = {"meta.json": json.dumps(LAPTOP_META).encode(),
                 "commits.jsonl": "".join(json.dumps(c) + "\n" for c in LAPTOP_COMMITS).encode(),
                 "audio.pcm": b"\0\0" * 8000}
        status, _ = self.upload("hazel", LAPTOP_META["id"], files)
        self.assertEqual(status, 200)
        d, meta, segs = self.draft("hazel", LAPTOP_META["id"])
        self.assertEqual(meta["text"], "first part second part")
        self.assertEqual(meta["engine"], "butternut GPU")
        self.assertEqual(meta["created_ms"], 1700000100000)
        self.assertEqual(meta["tier"], "personal")
        self.assertEqual(len(segs), 3)
        self.assertFalse(segs[1]["ok"])
        self.assertEqual(segs[2]["conf"]["lang_p"], 0.9)
        self.assertTrue((d / "audio.opus").stat().st_size > 0)

    def test_missing_or_odd_tier_is_personal(self):
        no_tier = {k: v for k, v in PHONE_META.items() if k != "tier"}
        files = self.phone_files()
        files["meta.json"] = json.dumps(no_tier).encode()
        self.upload("phone", "a1", files)
        self.assertEqual(self.draft("phone", "a1")[1]["tier"], "personal")
        self.upload("phone", "a2", self.phone_files(tier="Work"))
        self.assertEqual(self.draft("phone", "a2")[1]["tier"], "personal")

    def test_reupload_replaces(self):
        self.upload("phone", "r1", self.phone_files(text="first version"))
        self.upload("phone", "r1", self.phone_files(text="second version"))
        self.assertEqual(self.draft("phone", "r1")[1]["text"], "second version")
        self.assertEqual(sorted(p.name for p in (self.data / "drafts" / "phone").iterdir()), ["r1"])

    def test_partial_upload_leaves_no_draft(self):
        self.req("PUT", "/inbox/phone/p1/meta.json", json.dumps(PHONE_META).encode())
        self.assertFalse((self.data / "drafts" / "phone" / "p1").exists())

    def test_done_without_audio_is_400(self):
        self.req("PUT", "/inbox/phone/n1/meta.json", json.dumps(PHONE_META).encode())
        self.assertEqual(self.req("POST", "/inbox/phone/n1/done", b"")[0], 400)
        self.assertFalse((self.data / "drafts" / "phone" / "n1").exists())

    def test_bad_names_rejected(self):
        for path in ("/inbox/../x/meta.json", "/inbox/phone/../meta.json",
                     "/inbox/phone/x/evil.sh", "/inbox/Phone!/x/meta.json"):
            status, _ = self.req("PUT", path, b"{}")
            self.assertIn(status, (400, 404), path)
        # Nothing written anywhere: not even the data dir.
        self.assertEqual([p for p in self.root.rglob("*") if p.is_file()], [])

    def test_peer_check_rules(self):
        whois = {"100.64.0.1": {"UserProfile": {"ID": ME}, "Node": {"Tags": None}},
                 "100.64.0.2": {"UserProfile": {"ID": 8}, "Node": {"Tags": None}},
                 "100.64.0.3": {"UserProfile": {"ID": ME}, "Node": {"Tags": ["tag:agent-host"]}}}
        p = lab.PeerCheck(whois.get, ME)
        self.assertTrue(p.allowed("100.64.0.1"))
        self.assertFalse(p.allowed("100.64.0.2"))
        self.assertFalse(p.allowed("100.64.0.3"))
        self.assertFalse(p.allowed("192.168.1.5"))
        self.assertTrue(p.allowed("127.0.0.1"))

        def broken(ip):
            raise OSError("tailscale missing")
        self.assertFalse(lab.PeerCheck(broken, ME).allowed("100.64.0.1"))

    def test_foreign_peer_refused_before_writing(self):
        self.whois["127.0.0.1"] = {"UserProfile": {"ID": 8}, "Node": {"Tags": None}}
        strict = self.start(lab.PeerCheck(lambda ip: self.whois.get(ip), ME, allow_loopback=False))
        status, _ = self.req("PUT", "/inbox/phone/f1/meta.json", b"{}", server=strict)
        self.assertEqual(status, 403)
        self.assertFalse((self.data / "incoming" / "phone" / "f1").exists())
        # Answers are cached per address: a fresh check sees the owner.
        self.whois["127.0.0.1"] = {"UserProfile": {"ID": ME}, "Node": {"Tags": None}}
        owner = self.start(lab.PeerCheck(lambda ip: self.whois.get(ip), ME, allow_loopback=False))
        status, _ = self.req("PUT", "/inbox/phone/f2/meta.json", b"{}", server=owner)
        self.assertEqual(status, 204)

    def test_malformed_segments_is_400_and_server_lives(self):
        files = self.phone_files()
        files["segments.jsonl"] = b"1\n"
        status, _ = self.upload("phone", "m1", files)
        self.assertEqual(status, 400)
        self.assertEqual(self.req("GET", "/health")[0], 200)
        laptop = {"meta.json": json.dumps(dict(LAPTOP_META, t0="soon")).encode(),
                  "commits.jsonl": b"", "audio.pcm": b"\0\0" * 1600}
        self.assertEqual(self.upload("hazel", "m2", laptop)[0], 400)

    def test_concurrent_done_on_one_id_keeps_a_whole_draft(self):
        # The interleaving that loses the audio without a per-draft lock: the
        # first done writes its audio and is still finishing when the second
        # starts over in the same .tmp dir (its audio not written yet).
        import time
        real = lab.to_opus
        calls = []

        def staged(name, data, dest):
            calls.append(name)
            if len(calls) == 1:
                real(name, data, dest)
                time.sleep(0.4)
            else:
                time.sleep(0.8)
                real(name, data, dest)
        lab.to_opus = staged
        self.addCleanup(setattr, lab, "to_opus", real)
        for name, data in self.phone_files().items():
            self.req("PUT", f"/inbox/phone/c1/{name}", data)
        results = []

        def done():
            results.append(self.req("POST", "/inbox/phone/c1/done", b"")[0])
        first = threading.Thread(target=done)
        first.start()
        time.sleep(0.15)
        second = threading.Thread(target=done)
        second.start()
        first.join()
        second.join()
        self.assertIn(200, results)
        d = self.data / "drafts" / "phone" / "c1"
        self.assertTrue((d / "audio.opus").exists())
        self.assertTrue((d / "meta.json").exists())
        self.assertEqual(sorted(p.name for p in d.parent.iterdir()), ["c1"])

    def test_put_without_length_is_411(self):
        port = self.server.server_address[1]
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        c.putrequest("PUT", "/inbox/phone/l1/meta.json")
        c.endheaders()
        self.assertEqual(c.getresponse().status, 411)
        c.close()


def store_draft(data, origin, ident, created_ms, text):
    d = Path(data) / "drafts" / origin / ident
    d.mkdir(parents=True, exist_ok=True)
    meta = {"id": ident, "origin": origin, "created_ms": created_ms, "lang": "en", "tier": "work",
            "app": "kitty", "text": text, "duration": 2.0, "received_ms": created_ms + 1}
    (d / "meta.json").write_text(json.dumps(meta))
    (d / "segments.jsonl").write_text(json.dumps({"i": 0, "start": 0, "end": 16000, "text": " " + text,
                                                  "ok": True, "conf": {"avg_logprob": -0.1}}) + "\n")


class Api(unittest.TestCase):
    start = Inbox.start
    req = Inbox.req

    def mined(self, suspects, matches=(), server=None):
        body = json.dumps({"suspects": suspects, "matches": list(matches)}).encode()
        return self.req("POST", "/api/mined", body, server, {"Content-Length": str(len(body))})

    def suspect(self, **kw):
        s = {"draft": "hazel/d2", "segment": 0, "start": 1, "end": 8, "text": "ignored",
             "suggestion": "harmonia", "kind": "other", "source": "agent-diff", "score": 0.9}
        s.update(kw)
        return s

    def setUp(self):
        Inbox.setUp(self)
        store_draft(self.data, "hazel", "d1", 1000, "an early line")
        store_draft(self.data, "hazel", "d2", 5000, "hormonia restarts")

    def test_drafts_since(self):
        status, body = self.req("GET", "/api/drafts?since=2000")
        self.assertEqual(status, 200)
        drafts = json.loads(body)["drafts"]
        self.assertEqual([d["draft"] for d in drafts], ["hazel/d2"])
        self.assertEqual(drafts[0]["segments"], [{"i": 0, "text": " hormonia restarts", "ok": True}])
        self.assertEqual({k: drafts[0][k] for k in ("created_ms", "tier", "app", "lang", "text")},
                         {"created_ms": 5000, "tier": "work", "app": "kitty", "lang": "en",
                          "text": "hormonia restarts"})
        self.assertEqual(self.req("GET", "/api/drafts")[0], 400)
        self.assertEqual(self.req("GET", "/api/drafts?since=soon")[0], 400)

    def test_api_refuses_strangers(self):
        strict = self.start(lab.PeerCheck(lambda ip: None, ME, allow_loopback=False))
        self.assertEqual(self.req("GET", "/api/drafts?since=0", server=strict)[0], 403)
        self.assertEqual(self.mined([self.suspect()], server=strict)[0], 403)
        self.assertFalse((self.data / "suspects.jsonl").exists())

    def test_mined_validates_and_dedups(self):
        match = {"draft": "hazel/d2", "app": "kitty", "tier": "work", "sent_ms": 6000, "coverage": 0.9}
        status, body = self.mined([self.suspect()], [match])
        self.assertEqual((status, json.loads(body)), (200, {"added": 1}))
        self.assertEqual(json.loads(self.mined([self.suspect()], [match])[1]), {"added": 0})
        before = (self.data / "suspects.jsonl").read_text()
        for bad in (self.suspect(source="claude"), self.suspect(draft="hazel/nope"),
                    self.suspect(start=8, end=8), self.suspect(kind="vibes"), self.suspect(segment="0"),
                    self.suspect(draft="../x/d2")):
            self.assertEqual(self.mined([self.suspect(start=0, end=1), bad])[0], 400, bad)
        self.assertEqual((self.data / "suspects.jsonl").read_text(), before)
        self.assertEqual(len((self.data / "matches.jsonl").read_text().splitlines()), 1)

    def test_mined_text_from_store(self):
        self.mined([self.suspect()])
        row = json.loads((self.data / "suspects.jsonl").read_text())
        self.assertEqual(row["text"], "hormoni")
        self.assertEqual(row["id"], lab.suspect_id("hazel/d2", 0, 1, 8, "agent-diff"))

    def test_mined_empty_body_is_400(self):
        self.assertEqual(self.req("POST", "/api/mined", None)[0], 400)


if __name__ == "__main__":
    unittest.main()
