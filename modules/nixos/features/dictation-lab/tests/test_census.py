#!/usr/bin/env python3
"""Tests for `dictate-lab census` (training lab, plan 3): suspects per 100
words per week and source, totals by kind, the work-list hint, and repeated
edits (--pairs only).

Run: python3 -m unittest discover -s <this dir> -v
"""
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "dictate-lab.py"
spec = importlib.util.spec_from_file_location("dictate_lab_census", SCRIPT)
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)

NOW = 1_800_000_000_000
DAY = 86_400_000


# Invented text only (public repo).
def store(data, ident, words, tier="personal", origin="hazel", created_ms=NOW - DAY):
    d = Path(data) / "drafts" / origin / ident
    d.mkdir(parents=True)
    text = " ".join(["word"] * words)
    (d / "meta.json").write_text(json.dumps({"id": ident, "origin": origin, "created_ms": created_ms, "lang": "en",
                                             "tier": tier, "app": "kitty", "text": text, "received_ms": NOW}))


def suspects(data, rows):
    with open(Path(data) / "suspects.jsonl", "a") as f:
        for n, (draft, source, kind, text, suggestion) in enumerate(rows):
            f.write(json.dumps({"id": f"{len(rows)}-{n}-{draft}-{text}", "draft": draft, "segment": 0, "start": 0,
                                "end": 1, "text": text, "suggestion": suggestion, "kind": kind,
                                "source": source, "score": 0.9, "found_ms": NOW}) + "\n")


class Census(unittest.TestCase):
    def setUp(self):
        self.data = tempfile.mkdtemp(prefix="lab-census-")
        store(self.data, "w1", 60, tier="work")
        store(self.data, "p1", 40)
        suspects(self.data, [("hazel/w1", "heuristic", "term", "a", None),
                             ("hazel/w1", "heuristic", "term", "b", None),
                             ("hazel/p1", "heuristic", "hallucination", "c", None),
                             ("hazel/w1", "agent-diff", "other", "hormonia", "harmonia"),
                             ("hazel/p1", "agent-diff", "other", "hormonia", "harmonia")])

    def test_rates(self):
        c = lab.census(self.data, now_ms=NOW)
        self.assertEqual(len(c["weeks"]), 1)
        w = c["weeks"][0]
        self.assertEqual((w["drafts"], w["words"]), (2, 100))
        self.assertEqual(w["heuristic_per_100w"], 3.0)
        self.assertEqual(w["agent_diff_per_100w"], 2.0)
        self.assertRegex(w["week"], r"^\d{4}-W\d\d$")
        self.assertEqual(c["kinds"], {"term": 2, "other": 2, "hallucination": 1})

    def test_filters(self):
        w = lab.census(self.data, tier="work", now_ms=NOW)["weeks"][0]
        self.assertEqual((w["drafts"], w["words"]), (1, 60))
        self.assertEqual(w["heuristic_per_100w"], round(2 / 60 * 100, 1))
        self.assertEqual(lab.census(self.data, origin="phone", now_ms=NOW)["weeks"], [])

    def test_old_weeks_dropped(self):
        store(self.data, "old", 10, created_ms=NOW - 70 * DAY)
        self.assertEqual(len(lab.census(self.data, weeks=8, now_ms=NOW)["weeks"]), 1)

    def test_personal_apps(self):
        (Path(self.data) / "matches.jsonl").write_text(
            json.dumps({"draft": "hazel/p1", "app": "org.example.chat", "tier": "personal", "sent_ms": NOW,
                        "coverage": 0.9}) + "\n"
            + json.dumps({"draft": "hazel/w1", "app": "kitty", "tier": "work", "sent_ms": NOW,
                          "coverage": 0.9}) + "\n")
        c = lab.census(self.data, now_ms=NOW)
        self.assertEqual(c["personal_apps"], {"org.example.chat": 1})
        self.assertEqual(c["weeks"][0]["matched"], 2)

    def test_pairs(self):
        suspects(self.data, [("hazel/w1", "agent-diff", "other", "hormonia", "harmonia")])
        self.assertEqual(lab.pairs(self.data), [("hormonia", "harmonia", 3)])

    def test_default_output_has_no_text(self):
        suspects(self.data, [("hazel/w1", "agent-diff", "other", "QUIXOTIC", "QUIXOTIC-FIX"),
                             ("hazel/w1", "agent-diff", "other", "QUIXOTIC", "QUIXOTIC-FIX")])

        def cli(*extra):
            out = io.StringIO()
            old, sys.argv = sys.argv, ["dictate-lab", "census", "--data-dir", self.data, *extra]
            try:
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                    lab.main()
            finally:
                sys.argv = old
            return out.getvalue()

        suspects(self.data, [("hazel/p1", "agent-diff", "other", "SECRETWORD", "x"),
                             ("hazel/p1", "agent-diff", "other", "SECRETWORD", "x")])
        self.assertNotIn("SECRETWORD", cli("--tier", "work", "--pairs"))
        self.assertIn("SECRETWORD", cli("--tier", "personal", "--pairs"))
        plain = cli()
        self.assertIn("by kind:", plain)
        self.assertNotIn("QUIXOTIC", plain)
        self.assertNotIn("hormonia", plain)
        self.assertIn("QUIXOTIC", cli("--pairs"))

    def test_data_dir_defaults_to_env(self):
        out = io.StringIO()
        old_argv, sys.argv = sys.argv, ["dictate-lab", "census"]
        old_env = os.environ.get("DICTATE_LAB_DATA")
        os.environ["DICTATE_LAB_DATA"] = self.data
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                lab.main()
        finally:
            sys.argv = old_argv
            if old_env is None:
                os.environ.pop("DICTATE_LAB_DATA")
            else:
                os.environ["DICTATE_LAB_DATA"] = old_env
        self.assertIn("by kind:", out.getvalue())


if __name__ == "__main__":
    unittest.main()
