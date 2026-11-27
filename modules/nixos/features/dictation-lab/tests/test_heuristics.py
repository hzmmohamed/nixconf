#!/usr/bin/env python3
"""Tests for dictate-lab's heuristic suspects (training lab, plan 3): low
word probability, near-vocabulary words, out-of-dictionary words, text over
silence, stock phrases, Whisper loops, wrong script.

Run: python3 -m unittest discover -s <this dir> -v
"""
import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "dictate-lab.py"
spec = importlib.util.spec_from_file_location("dictate_lab_heuristics", SCRIPT)
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)

NOW = 1_800_000_000_000


# Invented text only (public repo).
def meta(text="", lang="en"):
    return {"id": "d1", "origin": "hazel", "lang": lang, "text": text}


def seg(i, text, conf=None):
    s = {"i": i, "start": i * 16000, "end": (i + 1) * 16000, "text": text, "ok": True}
    if conf is not None:
        s["conf"] = conf
    return s


def conf(words=(), no_speech=0.01):
    return {"avg_logprob": -0.3, "no_speech_prob": no_speech, "lang": "en", "lang_p": 0.9,
            "words": [{"w": w, "p": p, "start": 0.0, "end": 0.1} for w, p in words]}


def none(_words):
    return set()


def run(segments, vocab=(), oov=none, m=None):
    m = m or meta(" ".join(s["text"].strip() for s in segments))
    return lab.heuristic_suspects(m, segments, list(vocab), oov, NOW)


class Heuristics(unittest.TestCase):
    def test_low_probability_word(self):
        out = run([seg(0, " the quick test", conf([(" the", 0.99), (" quick", 0.9), (" test", 0.2)]))])
        self.assertEqual(len(out), 1)
        s = out[0]
        self.assertEqual({k: s[k] for k in ("draft", "segment", "start", "end", "text", "kind", "source")},
                         {"draft": "hazel/d1", "segment": 0, "start": 11, "end": 15, "text": "test",
                          "kind": "other", "source": "heuristic"})
        self.assertAlmostEqual(s["score"], 0.8, delta=1e-9)
        self.assertIsNone(s["suggestion"])
        self.assertEqual(s["found_ms"], NOW)

    def test_near_vocabulary(self):
        out = run([seg(0, "open sway and claud code")], vocab=["Sway", "Claude Code"], oov=lambda w: {"claud"})
        self.assertEqual([(s["text"], s["suggestion"], s["kind"]) for s in out if s["suggestion"]],
                         [("claud code", "Claude Code", "term")])

    def test_near_vocabulary_skips_dictionary_words_in_english(self):
        # "say", "way", "the code" are words: only an unknown word near an entry is a suspect.
        self.assertEqual(run([seg(0, "they say it goes that way with the code")], vocab=["Sway", "T3 Code"]), [])
        out = run([seg(0, "open the swey config")], vocab=["Sway"], oov=lambda w: {"swey"})
        self.assertEqual([(s["text"], s["suggestion"], s["score"]) for s in out], [("swey", "Sway", 0.8)])

    def test_near_vocabulary_without_dictionary_for_other_languages(self):
        out = run([seg(0, " مرحبا swey")], vocab=["Sway"], m=meta("مرحبا swey", lang="ar"))
        self.assertIn(("swey", "Sway"), [(s["text"], s["suggestion"]) for s in out])

    def test_short_vocabulary_entries_match_exactly_only(self):
        self.assertEqual(run([seg(0, "six of one")], vocab=["Nix"]), [])

    def test_out_of_dictionary_skips_arabic_and_vocab(self):
        asked = []

        def oov(words):
            asked.extend(words)
            return {"zorbly", "nixos"}

        out = run([seg(0, "zorbly مرحبا NixOS")], vocab=["NixOS"], oov=oov)
        self.assertEqual([s["text"] for s in out if s["kind"] == "term"], ["zorbly"])
        self.assertFalse([w for w in asked if lab.ARABIC.search(w)])
        self.assertNotIn("nixos", asked)

    def test_silence_stock_repeat_script(self):
        out = run([seg(0, " something here", conf(no_speech=0.9)),
                   seg(1, " Thank you."),
                   seg(2, " go go go go"),
                   seg(3, " hello مرحبا")])
        self.assertEqual([(s["segment"], s["kind"]) for s in sorted(out, key=lambda s: s["segment"])],
                         [(0, "hallucination"), (1, "hallucination"), (2, "hallucination"), (3, "language")])
        by_seg = {s["segment"]: s for s in out}
        self.assertEqual(by_seg[0]["text"], "something here")
        self.assertAlmostEqual(by_seg[0]["score"], 0.9, delta=1e-9)
        self.assertEqual(by_seg[2]["text"], "go go go go")

    def test_arabic_draft_without_arabic_letters(self):
        out = run([seg(0, " hello there")], m=meta("hello there", lang="ar"))
        self.assertEqual([s["kind"] for s in out], ["language"])

    def test_no_conf_and_no_segments(self):
        self.assertIsInstance(run([seg(0, " a plain line")]), list)
        out = lab.heuristic_suspects(meta("go go go"), [], [], none, NOW)
        self.assertEqual([(s["segment"], s["text"]) for s in out], [(None, "go go go")])

    def test_ids_stable_and_one_per_span(self):
        def oov(_words):
            return {"zorbly"}

        segments = [seg(0, " Zorbly", conf([(" Zorbly", 0.1)]))]
        a = run(segments, oov=oov)
        b = run(segments, oov=oov)
        self.assertEqual(len(a), 1)
        self.assertAlmostEqual(a[0]["score"], 0.9, delta=1e-9)
        self.assertEqual(a[0]["kind"], "term")
        self.assertEqual([s["id"] for s in a], [s["id"] for s in b])
        self.assertEqual(a[0]["id"], lab.suspect_id("hazel/d1", 0, 1, 7, "heuristic"))
        self.assertRegex(a[0]["id"], r"^[0-9a-f]{12}$")


if __name__ == "__main__":
    unittest.main()
