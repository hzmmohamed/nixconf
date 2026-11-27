#!/usr/bin/env python3
"""Tests for `dictate-lab mine` (training lab, plan 3): drafts are matched
to the messages the user sent to agents (Claude Code session logs), and the
user's small edits come back as agent-diff suspects.

Run: python3 -m unittest discover -s <this dir> -v
"""
import importlib.util
import json
import os
import tempfile
import threading
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "dictate-lab.py"
spec = importlib.util.spec_from_file_location("dictate_lab_mine", SCRIPT)
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)

T0 = 1_800_000_000_000
MIN = 60_000


def iso(ms):
    return datetime.fromtimestamp(ms / 1000, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def user_line(ms, content, **kw):
    line = {"type": "user", "userType": "external", "isSidechain": False, "timestamp": iso(ms),
            "message": {"role": "user", "content": content}}
    line.update(kw)
    return json.dumps(line)


def sessions(root, *lines):
    d = Path(root) / "-home-someone-project"
    d.mkdir(parents=True, exist_ok=True)
    (d / "s1.jsonl").write_text("\n".join(lines) + "\n")
    return Path(root)


# Invented text only (public repo).
def draft(text, created_ms=T0, duration=4.0, tier="work", app="kitty"):
    return {"draft": "hazel/d1", "created_ms": created_ms, "duration": duration, "tier": tier, "app": app,
            "lang": "en", "text": text, "segments": [{"i": 0, "text": " " + text, "ok": True}]}


class SentMessages(unittest.TestCase):
    def test_sent_messages_filters(self):
        root = sessions(tempfile.mkdtemp(prefix="lab-mine-"),
                        user_line(T0, "a plain sent message"),
                        user_line(T0 + 1, [{"type": "text", "text": "a list"}, {"type": "text", "text": "message"}]),
                        user_line(T0 + 2, [{"type": "tool_result", "content": "x"}]),
                        user_line(T0 + 3, "meta stuff", isMeta=True),
                        user_line(T0 + 4, "a subagent prompt", isSidechain=True),
                        user_line(T0 + 5, "<command-name>/compact</command-name>"),
                        json.dumps({"type": "assistant", "timestamp": iso(T0), "message": {"content": "no"}}),
                        '{"type": "user", "timest')
        os.utime(root / "-home-someone-project" / "s1.jsonl", (T0 / 1000, T0 / 1000))
        self.assertEqual(lab.sent_messages(root, T0 - MIN),
                         [(T0, "a plain sent message"), (T0 + 1, "a list\nmessage")])

    def test_old_session_files_skipped(self):
        root = sessions(tempfile.mkdtemp(prefix="lab-mine-"), user_line(T0, "a plain sent message"))
        old = time.time() - 10 * 86400
        os.utime(root / "-home-someone-project" / "s1.jsonl", (old, old))
        self.assertEqual(lab.sent_messages(root, int(time.time() * 1000) - 86_400_000), [])


class Match(unittest.TestCase):
    def test_match_window_and_coverage(self):
        d = draft("please open the sway config and fix the bar")
        edited = "Please open the Sway config, and fix the waybar."
        m = lab.match(d, [(T0 + 5 * MIN, edited)])
        self.assertIsNotNone(m)
        self.assertEqual(m[:2], (T0 + 5 * MIN, edited))
        self.assertGreaterEqual(m[2], 0.6)
        self.assertIsNone(lab.match(d, [(T0 + 120 * MIN, edited)]))
        self.assertIsNone(lab.match(d, [(T0 + 5 * MIN, "an unrelated note about lunch plans and the weather")]))
        self.assertIsNone(lab.match(draft("yes please"), [(T0 + MIN, "yes please")]))

    def test_best_match_wins(self):
        d = draft("please open the sway config and fix the bar")
        far = (T0 + 2 * MIN, "please open the sway config now")
        close = (T0 + 9 * MIN, "please open the sway config and fix the bar")
        self.assertEqual(lab.match(d, [far, close])[:2], close)

    def test_diff_suspects(self):
        d = draft("restart the hormonia cache on butter nut")
        out = lab.diff_suspects(d, "Restart the harmonia cache on butternut.")
        got = sorted((s["start"], s["end"], s["suggestion"], s["kind"], s["score"]) for s in out)
        self.assertEqual(got, [(1, 8, "Restart", "punct", 0.3),
                               (13, 21, "harmonia", "other", 0.9),
                               (31, 41, "butternut.", "other", 0.9)])
        text = d["segments"][0]["text"]
        self.assertEqual([text[s:e] for s, e, *_ in got], ["restart", "hormonia", "butter nut"])
        self.assertTrue(all(s["segment"] == 0 and s["source"] == "agent-diff" for s in out))

    def test_term_and_delete(self):
        out = lab.diff_suspects(draft("open the nix oh s config um now please"), "open the NixOS config now please")
        kinds = {(s["suggestion"], s["kind"], s["score"]) for s in out}
        self.assertIn(("NixOS", "term", 0.9), kinds)
        self.assertIn(("", "other", 0.6), kinds)

    def test_big_rewrite_ignored(self):
        d = draft("we should restart the cache on the box today please")
        self.assertEqual(lab.diff_suspects(
            d, "we should completely rebuild every single service everywhere on the box today please"), [])


class MineEndToEnd(unittest.TestCase):
    def test_mine_end_to_end(self):
        data = Path(tempfile.mkdtemp(prefix="lab-mine-data-"))
        now = int(time.time() * 1000)
        d = data / "drafts" / "hazel" / "d1"
        d.mkdir(parents=True)
        text = "please restart the hormonia cache on butter nut tonight"
        (d / "meta.json").write_text(json.dumps({"id": "d1", "origin": "hazel", "created_ms": now - 10 * MIN,
                                                 "lang": "en", "tier": "personal", "app": "org.example.chat",
                                                 "text": text, "duration": 3.0, "received_ms": now}))
        (d / "segments.jsonl").write_text(json.dumps({"i": 0, "start": 0, "end": 1, "text": " " + text,
                                                      "ok": True}) + "\n")
        root = sessions(tempfile.mkdtemp(prefix="lab-mine-s-"),
                        user_line(now - 8 * MIN, "Please restart the harmonia cache on butternut tonight."))
        server = lab.make_server(data, 0, lab.PeerCheck(lambda ip: None, 7), host="127.0.0.1")
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        url = f"http://127.0.0.1:{server.server_address[1]}"
        first = lab.mine(url, root, 3, now)
        self.assertEqual((first["drafts"], first["matched"]), (1, 1))
        self.assertGreaterEqual(first["added"], 1)
        match = json.loads((data / "matches.jsonl").read_text())
        self.assertEqual((match["draft"], match["tier"], match["app"]), ("hazel/d1", "personal", "org.example.chat"))
        self.assertEqual(lab.mine(url, root, 3, now)["added"], 0)

    def test_mine_unreachable_raises_oserror(self):
        with self.assertRaises(OSError):
            lab.mine("http://127.0.0.1:1", tempfile.mkdtemp(), 3, int(time.time() * 1000), timeout=2)


if __name__ == "__main__":
    unittest.main()
