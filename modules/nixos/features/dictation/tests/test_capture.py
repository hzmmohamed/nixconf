#!/usr/bin/env python3
"""Tests for dictate-stream's capture fields (training lab, plan 1): tier,
app, origin, prompt hash, Whisper verbose_json confidences.

dictate-stream.py is a script with a hyphenated name and module-level
config: it is loaded with importlib after DICTATE_CONFIG and XDG_RUNTIME_DIR
point at a temp dir. Run: python3 -m unittest discover -s <this dir> -v
(needs numpy and onnxruntime, as the script imports them).
"""
import hashlib
import importlib.util
import json
import os
import socket
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "dictate-stream.py"
TMP = tempfile.mkdtemp(prefix="dictate-test-")
CONFIG = {
    "servers": [], "threads": 4, "output": "print", "prompt": "NixOS, Sway.",
    "mode": "batch", "keep_days": 7, "default_lang": "en", "local_lang": "en",
    "whisper_model": "", "append_space": True, "work_apps": ["kitty"],
    "max_sec": 600, "no_speech_sec": 10, "pause_ms": 550, "max_segment_sec": 25,
    "workers": 1, "waybar_signal": 8, "journal_dir": os.path.join(TMP, "journal"),
    "vad_model": "", "overlay": {"enable": False, "css": "", "long_session_sec": 600},
    "bin": {},
}
with open(os.path.join(TMP, "dictate.json"), "w") as f:
    json.dump(CONFIG, f)
os.environ["DICTATE_CONFIG"] = os.path.join(TMP, "dictate.json")
os.environ["XDG_RUNTIME_DIR"] = TMP
for k in ("DICTATE_SERVERS", "DICTATE_OUTPUT", "DICTATE_JOURNAL_DIR"):
    os.environ.pop(k, None)

spec = importlib.util.spec_from_file_location("dictate_stream", SCRIPT)
ds = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ds)

# Invented text only (public repo).
VERBOSE = {
    "task": "transcribe", "language": "english", "duration": 4.0,
    "text": " the quick test of a sentence",
    "detected_language": "en", "detected_language_probability": 0.97,
    "segments": [
        {"id": 0, "text": " the quick", "start": 0.0, "end": 1.0, "temperature": 0.0,
         "avg_logprob": -0.2, "no_speech_prob": 0.01,
         "words": [{"word": " the", "start": 0.0, "end": 0.3, "t_dtw": -1, "probability": 0.99},
                   {"word": " quick", "start": 0.3, "end": 1.0, "t_dtw": -1, "probability": 0.81}]},
        {"id": 1, "text": " test of", "start": 1.0, "end": 2.0, "temperature": 0.0,
         "avg_logprob": -0.9, "no_speech_prob": 0.3,
         "words": [{"word": " test", "start": 1.0, "end": 1.5, "t_dtw": -1, "probability": 0.42},
                   {"word": " of", "start": 1.5, "end": 2.0, "t_dtw": -1, "probability": 0.9}]},
    ],
}


class Tier(unittest.TestCase):
    def test_tier_for(self):
        self.assertEqual(ds.tier_for("kitty", ["kitty"], None), "work")
        self.assertEqual(ds.tier_for("Kitty", ["kitty"], None), "work")
        self.assertEqual(ds.tier_for("firefox", ["kitty"], None), "personal")
        self.assertEqual(ds.tier_for("", ["kitty"], None), "personal")
        self.assertEqual(ds.tier_for("firefox", ["kitty"], "work"), "work")
        self.assertEqual(ds.tier_for("kitty", ["kitty"], "personal"), "personal")
        self.assertEqual(ds.tier_for("kitty", ["kitty"], "bogus"), "work")

    def test_prompt_sha(self):
        self.assertEqual(ds.prompt_sha("NixOS, Sway."),
                         hashlib.sha256(b"NixOS, Sway.").hexdigest()[:12])


class Inference(unittest.TestCase):
    def test_parse_inference_verbose(self):
        text, conf = ds.parse_inference(VERBOSE)
        self.assertEqual(text, VERBOSE["text"])
        self.assertEqual(conf["avg_logprob"], -0.9)
        self.assertEqual(conf["no_speech_prob"], 0.3)
        self.assertEqual(len(conf["words"]), 4)
        self.assertEqual(conf["words"][0], {"w": " the", "p": 0.99, "start": 0.0, "end": 0.3})
        self.assertEqual(conf["lang"], "en")
        self.assertEqual(conf["lang_p"], 0.97)

    def test_parse_inference_plain(self):
        self.assertEqual(ds.parse_inference({"text": "hello"}), ("hello", None))
        self.assertEqual(ds.parse_inference({"text": "hello", "segments": []}), ("hello", None))


class Drafts(unittest.TestCase):
    def test_draft_meta_has_tier_fields(self):
        d = ds.Draft.create("en", "batch", "mic", journal=True, t0=1_700_000_000,
                            app="kitty", tier="work")
        d.close_audio()
        with open(d.file("meta.json")) as f:
            meta = json.load(f)
        self.assertEqual(meta["app"], "kitty")
        self.assertEqual(meta["tier"], "work")
        self.assertEqual(meta["origin"], socket.gethostname())
        self.assertEqual(meta["prompt_sha"], ds.prompt_sha(ds.CFG["prompt"]))

    def test_old_draft_loads_as_personal(self):
        path = os.path.join(ds.DRAFTS, "2020-01-01_000000-abcd")
        os.makedirs(path)
        with open(os.path.join(path, "meta.json"), "w") as f:
            json.dump({"id": "2020-01-01_000000-abcd", "status": "done", "lang": "en"}, f)
        d = ds.Draft.load(path)
        self.assertEqual(d.meta.get("tier", "personal"), "personal")
        self.assertIn("2020-01-01_000000-abcd", [x.id for x in ds.list_drafts()])

    def test_commit_entry_carries_confidence(self):
        conf = {"avg_logprob": -0.5, "no_speech_prob": 0.1, "words": [], "lang": "en", "lang_p": 0.9}
        self.assertEqual(ds.commit_entry(0, 0, 16000, True, "x", False, conf),
                         {"i": 0, "start": 0, "end": 16000, "ok": True, "text": "x",
                          "delivered": False, "conf": conf})
        self.assertNotIn("conf", ds.commit_entry(1, 0, 16000, True, "x", True, None))


if __name__ == "__main__":
    unittest.main()
