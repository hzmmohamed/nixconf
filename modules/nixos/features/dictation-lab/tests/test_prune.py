#!/usr/bin/env python3
"""Tests for dictate-lab prune (training lab, plan 2): full audio goes after
audio_days unless the draft's language is kept; text and segments stay."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "dictate-lab.py"
spec = importlib.util.spec_from_file_location("dictate_lab", SCRIPT)
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)

DAY = 86_400_000
NOW = 1_800_000_000_000


class Prune(unittest.TestCase):
    def draft(self, data, ident, lang, age_days):
        d = data / "drafts" / "phone" / ident
        d.mkdir(parents=True)
        (d / "meta.json").write_text(json.dumps({"id": ident, "lang": lang,
                                                 "received_ms": NOW - age_days * DAY}))
        (d / "segments.jsonl").write_text("")
        (d / "audio.opus").write_bytes(b"OggS")
        return d

    def test_prune_drops_old_audio_keeps_arabic_and_text(self):
        data = Path(tempfile.mkdtemp(prefix="lab-prune-"))
        old_en = self.draft(data, "old-en", "en", 91)
        old_ar = self.draft(data, "old-ar", "ar", 400)
        new_en = self.draft(data, "new-en", "en", 10)
        self.assertEqual(lab.prune(data, 90, ["ar"], NOW), 1)
        self.assertFalse((old_en / "audio.opus").exists())
        self.assertTrue((old_en / "meta.json").exists())
        self.assertTrue((old_en / "segments.jsonl").exists())
        self.assertTrue((old_ar / "audio.opus").exists())
        self.assertTrue((new_en / "audio.opus").exists())


if __name__ == "__main__":
    unittest.main()
