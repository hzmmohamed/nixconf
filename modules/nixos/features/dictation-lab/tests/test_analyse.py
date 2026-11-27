#!/usr/bin/env python3
"""Tests for `dictate-lab analyse` (training lab, plan 3): heuristic
suspects over the lab tree go to suspects.jsonl once, re-uploads are
re-analysed, odd dirs are skipped, transcript text is never logged.

Run: python3 -m unittest discover -s <this dir> -v
"""
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "dictate-lab.py"
spec = importlib.util.spec_from_file_location("dictate_lab_analyse", SCRIPT)
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)

NOW = 1_800_000_000_000


def none(_words):
    return set()


# Invented text only (public repo).
def write_draft(data, ident, segments, received_ms=1000, origin="hazel", lang="en", **extra):
    d = Path(data) / "drafts" / origin / ident
    d.mkdir(parents=True, exist_ok=True)
    text = " ".join(s["text"].strip() for s in segments)
    meta = {"id": ident, "origin": origin, "created_ms": 1000, "lang": lang, "tier": "personal",
            "app": None, "text": text, "duration": 1.0, "received_ms": received_ms, **extra}
    (d / "meta.json").write_text(json.dumps(meta))
    (d / "segments.jsonl").write_text("".join(json.dumps(s) + "\n" for s in segments))
    return d


def seg(i, text):
    return {"i": i, "start": 0, "end": 16000, "text": text, "ok": True}


def lines(path):
    return Path(path).read_text().splitlines() if Path(path).exists() else []


class Analyse(unittest.TestCase):
    def setUp(self):
        self.data = tempfile.mkdtemp(prefix="lab-analyse-")
        self.suspects = Path(self.data) / "suspects.jsonl"

    def test_analyse_appends_then_is_idempotent(self):
        write_draft(self.data, "a1", [seg(0, " go go go"), seg(1, " Thank you.")])
        first = lab.analyse(self.data, [], none, NOW)
        self.assertEqual(first["drafts"], 1)
        self.assertGreater(first["added"], 0)
        n = len(lines(self.suspects))
        self.assertEqual(n, first["added"])
        self.assertEqual(lab.analyse(self.data, [], none, NOW), {"drafts": 0, "added": 0})
        self.assertEqual(len(lines(self.suspects)), n)

    def test_reupload_is_reanalysed_without_duplicates(self):
        write_draft(self.data, "a1", [seg(0, " go go go")])
        lab.analyse(self.data, [], none, NOW)
        write_draft(self.data, "a1", [seg(0, " go go go"), seg(1, " Thank you.")], received_ms=2000)
        again = lab.analyse(self.data, [], none, NOW)
        self.assertEqual(again, {"drafts": 1, "added": 1})
        ids = [json.loads(x)["id"] for x in lines(self.suspects)]
        self.assertEqual(len(ids), len(set(ids)))

    def test_redo_runs_every_draft(self):
        write_draft(self.data, "a1", [seg(0, " go go go")])
        lab.analyse(self.data, [], none, NOW)
        self.assertEqual(lab.analyse(self.data, [], none, NOW, redo=True), {"drafts": 1, "added": 0})

    def test_skips_tmp_and_broken_meta(self):
        write_draft(self.data, "x.tmp", [seg(0, " go go go")])
        broken = Path(self.data) / "drafts" / "hazel" / "b1"
        broken.mkdir(parents=True)
        (broken / "meta.json").write_text("{")
        self.assertEqual([k for k, _, _ in lab.iter_drafts(self.data)], [])
        self.assertEqual(lab.analyse(self.data, [], none, NOW), {"drafts": 0, "added": 0})

    def test_append_unique_under_concurrency(self):
        rows = [{"id": f"{i:012x}", "n": i} for i in range(50)]
        threads = [threading.Thread(target=lab.append_unique, args=(self.data, "suspects.jsonl", rows))
                   for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(len(lines(self.suspects)), 50)
        self.assertEqual(lab.append_unique(self.data, "matches.jsonl", [{"draft": "a/b"}], key="draft"), 1)
        self.assertEqual(lab.append_unique(self.data, "matches.jsonl", [{"draft": "a/b"}], key="draft"), 0)

    @unittest.skipUnless(os.environ.get("DICTATE_TEST_HUNSPELL_DICT"), "needs hunspell and a dictionary")
    def test_hunspell_oov_real(self):
        oov = lab.hunspell_oov(os.environ.get("DICTATE_TEST_HUNSPELL", "hunspell"),
                               os.environ["DICTATE_TEST_HUNSPELL_DICT"])
        self.assertEqual(oov(["hello", "zorblyx"]), {"zorblyx"})

    def test_hunspell_oov_without_hunspell(self):
        self.assertEqual(lab.hunspell_oov(None, None)(["zorblyx"]), set())

    def test_analyse_logs_no_text(self):
        write_draft(self.data, "m1", [seg(0, " QUIXOTIC-MARKER go go go")])
        vocab = Path(self.data) / "vocab.json"
        vocab.write_text(json.dumps(["Sway"]))
        err = io.StringIO()
        argv = ["dictate-lab", "analyse", "--data-dir", self.data, "--vocab", str(vocab)]
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(err):
            old, sys.argv = sys.argv, argv
            try:
                lab.main()
            finally:
                sys.argv = old
        self.assertIn("analysed 1 drafts", err.getvalue())
        self.assertNotIn("QUIXOTIC", err.getvalue())


if __name__ == "__main__":
    unittest.main()
