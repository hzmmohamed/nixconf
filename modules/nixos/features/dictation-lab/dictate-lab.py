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
      GET  /api/drafts?since=<ms>        recent drafts' text and segments (for mine)
      POST /api/mined                    {"suspects": [...], "matches": [...]} from mine
  dictate-lab prune --data-dir D --audio-days N [--keep-lang ar ...]
      drop full audio older than N days (text and segments stay)
  dictate-lab analyse --data-dir D --vocab V.json [--hunspell H --dict D] [--all]
      heuristic suspects of new or re-uploaded drafts -> <data>/suspects.jsonl
  dictate-lab mine --lab URL --sessions ~/.claude/projects [--days 3]
      (any agent host) match recent drafts to the messages sent from this
      host's agent sessions; post the user's edits as suspects
  dictate-lab census --data-dir D [--weeks N] [--origin O] [--tier T] [--lang L] [--pairs]
      counts per week (suspects per 100 words); --pairs adds repeated edits

Only loopback and the user's own untagged tailnet devices get in
(`tailscale whois`); anything else, or a whois that fails, gets 403 before
a byte is written. Transcript text is never logged. Python stdlib only.
"""

import argparse
import difflib
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime
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
    for line in (data or b"").split(b"\n"):
        if not line.strip():
            continue
        try:
            out.append(json.loads(line.decode()))
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


# --- mine: the user's edits to dictated agent prompts -------------------------
# A draft pasted into Claude Code (or T3, whose Claude threads land in the
# same logs) and edited before sending: the edits are near-certain
# corrections. Only diffs locally; no model.
MIN_WORDS = 4
MIN_COVERAGE = 0.6
MAX_EDIT = 4
MAX_REGION = 2  # the matched part of a message is at most twice the draft
WINDOW_BEFORE_MS = 60_000
WINDOW_AFTER_MS = 30 * 60_000


def _ts_ms(stamp):
    return int(datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp() * 1000)


def sent_messages(sessions_dir, since_ms):
    """(ts_ms, text) of the messages the user typed into agent sessions
    (~/.claude/projects/*/*.jsonl) since since_ms: no tool results, meta
    lines, subagent prompts or slash commands."""
    out = []
    for f in sorted(Path(sessions_dir).glob("*/*.jsonl")):
        try:
            if f.stat().st_mtime * 1000 < since_ms:
                continue
            lines = f.read_bytes()
        except OSError:
            continue
        for line in _jsonl(lines):
            if not isinstance(line, dict) or line.get("type") != "user" or line.get("userType") != "external" \
                    or line.get("isMeta") or line.get("isSidechain"):
                continue
            content = (line.get("message") or {}).get("content")
            if isinstance(content, list):
                if any(not isinstance(c, dict) or c.get("type") != "text" for c in content):
                    continue
                content = "\n".join(str(c.get("text") or "") for c in content)
            if not isinstance(content, str) or not content.strip() or content.lstrip().startswith("<"):
                continue
            try:
                ts = _ts_ms(line["timestamp"])
            except (KeyError, TypeError, ValueError):
                continue
            if ts >= since_ms:
                out.append((ts, content))
    return out


def _keys(text):
    return [k for k in (norm(t) for _, _, t in tokens(text)) if k]


def match(draft, messages):
    """The sent message the draft most likely became: (ts_ms, text,
    coverage), coverage being the share of the draft's words found in it."""
    keys = _keys(draft.get("text"))
    created = draft.get("created_ms")
    if len(keys) < MIN_WORDS or not isinstance(created, (int, float)):
        return None
    last = created + (draft.get("duration") or 0) * 1000 + WINDOW_AFTER_MS
    best = None
    for ts, text in messages:
        if not created - WINDOW_BEFORE_MS <= ts <= last:
            continue
        sm = difflib.SequenceMatcher(None, keys, _keys(text), autojunk=False)
        blocks = [b for b in sm.get_matching_blocks() if b.size]
        if not blocks:
            continue
        coverage = sum(b.size for b in blocks) / len(keys)
        region = blocks[-1].b + blocks[-1].size - blocks[0].b  # message words the draft spans
        if coverage >= MIN_COVERAGE and region <= MAX_REGION * len(keys) and (best is None or coverage > best[2]):
            best = (ts, text, coverage)
    return best


def _draft_tokens(draft):
    """(segment, start, end, raw) of the draft's words, offsets into their
    segment's text (or meta text with segment None)."""
    segs = [s for s in draft.get("segments") or [] if s.get("ok", True) and (s.get("text") or "").strip()]
    if not segs:
        segs = [{"i": None, "text": draft.get("text") or ""}]
    return [(s["i"], a, b, t) for s in segs for a, b, t in tokens(s["text"]) if norm(t)]


def _seg_text(draft, segment):
    if segment is None:
        return draft.get("text") or ""
    return next(s.get("text", "") for s in draft.get("segments") or [] if s.get("i") == segment)


def diff_suspects(draft, message):
    """The user's edits as suspects (no id/text/found_ms yet): replacements
    and deletions of at most MAX_EDIT words a side, and case/punctuation
    changes on matched words. Words the user added are not suspects."""
    dt = _draft_tokens(draft)
    mt = [t for _, _, t in tokens(message) if norm(t)]
    sm = difflib.SequenceMatcher(None, [norm(t[3]) for t in dt], [norm(t) for t in mt], autojunk=False)
    ops = sm.get_opcodes()
    out = []

    def span(i1, i2, kind, score, suggestion):
        first = dt[i1]
        same = [t for t in dt[i1:i2] if t[0] == first[0]]
        out.append({"draft": draft.get("draft"), "segment": first[0], "start": first[1], "end": same[-1][2],
                    "suggestion": suggestion, "kind": kind, "source": "agent-diff", "score": score})

    for n, (op, i1, i2, j1, j2) in enumerate(ops):
        if op == "equal":
            for k in range(i2 - i1):
                if dt[i1 + k][3] != mt[j1 + k]:
                    span(i1 + k, i1 + k + 1, "punct", 0.3, mt[j1 + k])
        elif op == "replace" and i2 - i1 <= MAX_EDIT and j2 - j1 <= MAX_EDIT:
            words = mt[j1:j2]
            bare = [w.strip(PUNCT) for w in words]
            term = any(re.search(r"[\d\-_./]", w) or any(c.isupper() for c in w[1:]) for w in bare)
            span(i1, i2, "term" if term else "other", 0.9, " ".join(words))
        elif op == "delete" and i2 - i1 <= MAX_EDIT and 0 < n < len(ops) - 1:
            span(i1, i2, "other", 0.6, "")
    return out


def mine(lab_url, sessions_dir, days, now_ms, timeout=20):
    """Match the lab's recent drafts to the messages sent from this host's
    agent sessions and post the edits back. Raises OSError if the lab is
    unreachable."""
    since = now_ms - days * 86_400_000
    with urllib.request.urlopen(f"{lab_url}/api/drafts?since={since}", timeout=timeout) as r:
        drafts = json.loads(r.read())["drafts"]
    messages = sent_messages(sessions_dir, since)
    suspects, matches = [], []
    for d in drafts:
        m = match(d, messages)
        if not m:
            continue
        matches.append({"draft": d["draft"], "app": d.get("app"), "tier": d.get("tier") or "personal",
                        "sent_ms": m[0], "coverage": round(m[2], 3)})
        suspects.extend(diff_suspects(d, m[1]))
    added = 0
    if matches:
        body = json.dumps({"suspects": suspects, "matches": matches}).encode()
        req = urllib.request.Request(f"{lab_url}/api/mined", data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            added = json.loads(r.read())["added"]
    return {"drafts": len(drafts), "matched": len(matches), "added": added}


# --- census -------------------------------------------------------------------
def _rows(data_dir, name):
    path = Path(data_dir) / name
    try:
        return [r for r in _jsonl(path.read_bytes()) if isinstance(r, dict)] if path.exists() else []
    except OSError:
        return []


def _week(ms):
    year, week, _ = datetime.fromtimestamp(ms / 1000).isocalendar()
    return f"{year}-W{week:02d}"


def select(data_dir, weeks=8, origin=None, tier=None, lang=None, now_ms=None):
    """{"<origin>/<id>": (week, words)} of the drafts a census covers."""
    now_ms = now_ms if now_ms is not None else int(time.time() * 1000)
    since = now_ms - weeks * 7 * 86_400_000
    drafts = {}
    for key, meta, _ in iter_drafts(data_dir):
        created = meta.get("created_ms")
        if not isinstance(created, (int, float)) or created < since:
            continue
        if (origin and meta.get("origin") != origin) or (tier and meta.get("tier") != tier) \
                or (lang and meta.get("lang") != lang):
            continue
        drafts[key] = (_week(created), len(tokens(meta.get("text"))))
    return drafts


def census(data_dir, weeks=8, origin=None, tier=None, lang=None, now_ms=None):
    """Counts only (no transcript text): per local ISO week, drafts, words and
    suspects per 100 words by source; suspects by kind; apps whose personal
    drafts turned up in agent sessions (a hint for the work list)."""
    drafts = select(data_dir, weeks, origin, tier, lang, now_ms)
    table = {}
    for week, words in drafts.values():
        w = table.setdefault(week, {"week": week, "drafts": 0, "words": 0, "heuristic": 0, "agent-diff": 0,
                                    "matched": 0})
        w["drafts"] += 1
        w["words"] += words
    kinds = {}
    for s in _rows(data_dir, "suspects.jsonl"):
        if s.get("draft") in drafts:
            w = table[drafts[s["draft"]][0]]
            if s.get("source") in ("heuristic", "agent-diff"):
                w[s["source"]] += 1
            kinds[s.get("kind")] = kinds.get(s.get("kind"), 0) + 1
    personal_apps = {}
    for m in _rows(data_dir, "matches.jsonl"):
        if m.get("draft") in drafts:
            table[drafts[m["draft"]][0]]["matched"] += 1
            if m.get("tier") == "personal" and m.get("app"):
                personal_apps[m["app"]] = personal_apps.get(m["app"], 0) + 1

    def rate(n, words):
        return round(n / words * 100, 1) if words else 0

    rows = [{"week": w["week"], "drafts": w["drafts"], "words": w["words"],
             "heuristic_per_100w": rate(w["heuristic"], w["words"]),
             "agent_diff_per_100w": rate(w["agent-diff"], w["words"]), "matched": w["matched"]}
            for w in sorted(table.values(), key=lambda w: w["week"])]
    return {"weeks": rows, "kinds": kinds, "personal_apps": personal_apps}


def pairs(data_dir, min_count=2, drafts=None):
    """(text, suggestion, n) of the user's repeated agent-prompt edits, in
    `drafts` (keys) only when given."""
    counts = {}
    for s in _rows(data_dir, "suspects.jsonl"):
        if s.get("source") == "agent-diff" and s.get("kind") != "punct" and (drafts is None or s.get("draft") in drafts):
            k = (s.get("text"), s.get("suggestion"))
            counts[k] = counts.get(k, 0) + 1
    return sorted(((t, g, n) for (t, g), n in counts.items() if n >= min_count), key=lambda x: (-x[2], x[0] or ""))


def print_census(c, top_pairs=None):
    print(f"{'week':<9} {'drafts':>6} {'words':>7} {'heur/100w':>9} {'edits/100w':>10} {'matched':>7}")
    for w in c["weeks"]:
        print(f"{w['week']:<9} {w['drafts']:>6} {w['words']:>7} {w['heuristic_per_100w']:>9} "
              f"{w['agent_diff_per_100w']:>10} {w['matched']:>7}")
    kinds = sorted(c["kinds"].items(), key=lambda kv: -kv[1])
    print("by kind: " + (" · ".join(f"{k} {n}" for k, n in kinds) or "none yet"))
    apps = sorted(c["personal_apps"].items(), key=lambda kv: -kv[1])
    print("personal drafts seen in agent sessions: " + (", ".join(f"{a} {n}" for a, n in apps) or "none"))
    if top_pairs is not None:
        print("repeated edits (you changed → to):")
        for text, suggestion, n in top_pairs:
            print(f"  {n:>3}×  {text!r} → {suggestion!r}")


MINED_MAX = 16 * 1024 * 1024
DRAFT_KEY = re.compile(r"^([^/]+)/([^/]+)$")


def _stored(data_dir, draft):
    """meta and segments of a stored draft "<origin>/<id>", or ValueError."""
    m = DRAFT_KEY.match(draft) if isinstance(draft, str) else None
    if not m or not valid(m.group(1), m.group(2)):
        raise ValueError("bad draft")
    d = Path(data_dir) / "drafts" / m.group(1) / m.group(2)
    if not (d / "meta.json").exists():
        raise ValueError("no such draft")
    seg_file = d / "segments.jsonl"
    return json.loads((d / "meta.json").read_text()), _jsonl(seg_file.read_bytes()) if seg_file.exists() else []


def drafts_since(data_dir, since_ms):
    out = []
    for key, meta, segments in iter_drafts(data_dir):
        created = meta.get("created_ms")
        if isinstance(created, (int, float)) and created >= since_ms:
            out.append({"draft": key, **{k: meta.get(k) for k in ("created_ms", "duration", "tier", "app", "lang", "text")},
                        "segments": [{"i": s.get("i"), "text": s.get("text", ""), "ok": s.get("ok", True)} for s in segments]})
    return out


def mined_rows(data_dir, body, now_ms):
    """Validated suspects and matches from a `mine` post; ValueError if any
    is invalid. Ids, found_ms and the span text come from the store."""
    if not isinstance(body, dict) or not isinstance(body.get("suspects", []), list) \
            or not isinstance(body.get("matches", []), list):
        raise ValueError("bad body")
    suspects = []
    for s in body.get("suspects", []):
        if not isinstance(s, dict) or s.get("source") != "agent-diff" or s.get("kind") not in KINDS:
            raise ValueError("bad suspect")
        meta, segments = _stored(data_dir, s.get("draft"))
        seg, start, end, score = s.get("segment"), s.get("start"), s.get("end"), s.get("score")
        if seg is None:
            text = meta.get("text") or ""
        elif type(seg) is int:
            text = next((x.get("text", "") for x in segments if x.get("i") == seg), None)
            if text is None:
                raise ValueError("no such segment")
        else:
            raise ValueError("bad segment")
        if type(start) is not int or type(end) is not int or not 0 <= start < end <= len(text):
            raise ValueError("bad span")
        if not isinstance(score, (int, float)) or not isinstance(s.get("suggestion"), (str, type(None))):
            raise ValueError("bad suspect")
        suspects.append(make_suspect(s["draft"], seg, text, start, end, s["kind"], "agent-diff", float(score),
                                     s.get("suggestion"), now_ms))
    matches = []
    for m in body.get("matches", []):
        if not isinstance(m, dict) or m.get("tier") not in ("work", "personal") \
                or not isinstance(m.get("app"), (str, type(None))) or type(m.get("sent_ms")) is not int \
                or not isinstance(m.get("coverage"), (int, float)):
            raise ValueError("bad match")
        _stored(data_dir, m.get("draft"))
        matches.append({k: m[k] for k in ("draft", "app", "tier", "sent_ms", "coverage")})
    return suspects, matches


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
            elif self.path.startswith("/api/"):
                if not peers.allowed(self.client_address[0]):
                    self.reply(403, {"error": "not one of your devices"})
                    return
                url = urllib.parse.urlsplit(self.path)
                since = urllib.parse.parse_qs(url.query).get("since", [""])[0]
                if url.path != "/api/drafts":
                    self.reply(404, {"error": "no such route"})
                elif not re.fullmatch(r"\d{1,16}", since):
                    self.reply(400, {"error": "since=<ms> required"})
                else:
                    self.reply(200, {"drafts": drafts_since(data_dir, int(since))})
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

        def api_post(self):
            if not peers.allowed(self.client_address[0]):
                self.reply(403, {"error": "not one of your devices"})
                return
            if self.path != "/api/mined":
                self.reply(404, {"error": "no such route"})
                return
            length = self.headers.get("Content-Length")
            if length is None:
                self.reply(411, {"error": "Content-Length required"})
                return
            if int(length) > MINED_MAX:
                self.reply(413, {"error": "too large"})
                return
            try:
                suspects, matches = mined_rows(data_dir, json.loads(self.rfile.read(int(length)) or b"null"),
                                               int(time.time() * 1000))
            except (ValueError, KeyError, TypeError, OSError) as err:
                self.reply(400, {"error": str(err) if isinstance(err, ValueError) else type(err).__name__})
                return
            added = append_unique(data_dir, "suspects.jsonl", suspects)
            append_unique(data_dir, "matches.jsonl", matches, key="draft")
            log(f"mined: {len(suspects)} suspects ({added} new), {len(matches)} matches")
            self.reply(200, {"added": added})

        def do_POST(self):
            if self.path.startswith("/api/"):
                self.api_post()
                return
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


# --- suspects -----------------------------------------------------------------
# A suspect is a span of one segment's text (character offsets, half-open;
# segment None = offsets into meta.text) that is likely mis-transcribed.
KINDS = ("term", "punct", "language", "hallucination", "grammar", "other")
LOW_P = 0.35
NO_SPEECH = 0.6
REPEAT = 3
STOCK = {"thank you.", "thanks for watching!", "thank you for watching.", "you"}
ARABIC = re.compile(r"[؀-ۿ]")
LATIN_WORD = re.compile(r"[A-Za-z][A-Za-z'-]*")
PUNCT = ".,;:!?\"'()[]،؛؟"


def tokens(text):
    return [(m.start(), m.end(), m.group()) for m in re.finditer(r"\S+", text or "")]


def norm(token):
    return token.strip(PUNCT).lower()


def suspect_id(draft, segment, start, end, source):
    return hashlib.sha1(f"{draft}|{segment}|{start}|{end}|{source}".encode()).hexdigest()[:12]


def make_suspect(draft, segment, seg_text, start, end, kind, source, score, suggestion=None, now_ms=None):
    return {"id": suspect_id(draft, segment, start, end, source), "draft": draft, "segment": segment,
            "start": start, "end": end, "text": seg_text[start:end], "suggestion": suggestion,
            "kind": kind, "source": source, "score": score,
            "found_ms": now_ms if now_ms is not None else int(time.time() * 1000)}


def levenshtein(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def _whole(text):
    """The span of a segment's text without its surrounding whitespace."""
    start = len(text) - len(text.lstrip())
    return start, len(text.rstrip())


def heuristic_suspects(meta, segments, vocab, oov, now_ms):
    """Rule-based suspects for one draft: low word probability, near a
    vocabulary entry (only with an out-of-dictionary word in it),
    out of dictionary (Latin-script words of English
    drafts), text over silence, stock phrases, repeats, wrong script. One
    suspect per span; the highest score wins."""
    draft = f"{meta.get('origin')}/{meta.get('id')}"
    lang = meta.get("lang")
    if segments:
        segs = [s for s in segments if s.get("ok", True) and (s.get("text") or "").strip()]
    else:
        segs = [{"i": None, "text": meta.get("text") or ""}] if (meta.get("text") or "").strip() else []
    vocab_words = {w.lower() for e in vocab for w in e.split()}

    def candidate(tok):
        # hunspell sees the word as spoken-cased ("London", "I'm"), not lowercased
        w = tok.strip(PUNCT)
        return w if LATIN_WORD.fullmatch(w) and w.lower() not in vocab_words else None

    # Latin-script words of any draft; out-of-dictionary suspects only for
    # English ones, the rest gates the near-vocabulary rule.
    words = sorted({c for s in segs for _, _, t in tokens(s["text"]) if (c := candidate(t))})
    unknown = oov(words) if words else set()

    found = {}

    def add(s, start, end, kind, score, suggestion=None):
        if start >= end:
            return
        key = (s["i"], start, end)
        if key not in found or score > found[key]["score"]:
            found[key] = make_suspect(draft, s["i"], s["text"], start, end, kind, "heuristic", score,
                                      suggestion, now_ms)

    for s in segs:
        text = s["text"]
        toks = tokens(text)
        conf = s.get("conf") if isinstance(s.get("conf"), dict) else {}
        whole = _whole(text)

        cursor = 0
        for w in conf.get("words") or []:
            word = str(w.get("w") or "").strip()
            p = w.get("p")
            if not word or not isinstance(p, (int, float)):
                continue
            at = text.find(word, cursor)
            if at < 0:
                continue
            cursor = at + len(word)
            if p < LOW_P:
                first = bool(toks) and at == toks[0][0]
                term = ((word[:1].isupper() and not first) or re.search(r"[\d\-_./]", word)
                        or candidate(word) in unknown)
                add(s, at, at + len(word), "term" if term else "other", 1 - p)

        for entry in vocab:
            if len(entry) <= 3:
                continue  # "Nix" vs "six": too short to guess at
            n = len(entry.split())
            limit = 1 if len(entry) <= 5 else 2
            for k in range(len(toks) - n + 1):
                gram = toks[k:k + n]
                key = " ".join(norm(t) for _, _, t in gram)
                if not key or key == entry.lower() or (n == 1 and key in vocab_words):
                    continue
                if not any(candidate(t) in unknown for _, _, t in gram):
                    continue  # "say" is a word, not a misheard "Sway"
                if levenshtein(key, entry.lower()) <= limit:
                    add(s, gram[0][0], gram[-1][1], "term", 0.8, entry)

        for start, end, t in toks:
            if lang == "en" and candidate(t) in unknown:
                add(s, start, end, "term", 0.5)

        nsp = conf.get("no_speech_prob")
        if isinstance(nsp, (int, float)) and nsp > NO_SPEECH:
            add(s, *whole, "hallucination", nsp)
        if text.strip().lower() in STOCK:
            add(s, *whole, "hallucination", 0.7)

        keys = [norm(t) for _, _, t in toks]
        for n in range(1, 5):
            k = 0
            while k + n <= len(keys):
                gram = keys[k:k + n]
                reps = 1
                while keys[k + reps * n:k + (reps + 1) * n] == gram:
                    reps += 1
                if reps >= REPEAT and all(gram):
                    add(s, toks[k][0], toks[k + reps * n - 1][1], "hallucination", 0.9)
                    k += reps * n
                else:
                    k += 1

        has_arabic = bool(ARABIC.search(text))
        if (lang == "en" and has_arabic) or (lang == "ar" and not has_arabic):
            add(s, *whole, "language", 0.6)

    return list(found.values())


def iter_drafts(data_dir):
    """("<origin>/<id>", meta, segments) for every stored draft; dirs mid-swap
    (.tmp) and drafts whose meta does not parse are skipped."""
    for meta_file in sorted(Path(data_dir).glob("drafts/*/*/meta.json")):
        d = meta_file.parent
        if d.name.endswith((".tmp", ".old")):
            continue
        try:
            meta = json.loads(meta_file.read_text())
            seg_file = d / "segments.jsonl"
            segments = _jsonl(seg_file.read_bytes()) if seg_file.exists() else []
        except (OSError, ValueError):
            continue
        if isinstance(meta, dict):
            yield f"{d.parent.name}/{d.name}", meta, [s for s in segments if isinstance(s, dict)]


def append_unique(data_dir, name, rows, key="id"):
    """Append the rows whose `key` is not in <data_dir>/<name> yet, under an
    exclusive lock shared by the server and analyse. Returns how many."""
    data_dir = Path(data_dir)
    data_dir.mkdir(parents=True, exist_ok=True)
    with open(data_dir / "suspects.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = data_dir / name
        seen = {r.get(key) for r in _jsonl(path.read_bytes())} if path.exists() else set()
        new = []
        for r in rows:
            if r.get(key) not in seen:
                seen.add(r.get(key))
                new.append(r)
        if new:
            torn = path.exists() and path.stat().st_size and not path.read_bytes().endswith(b"\n")
            with open(path, "a") as f:
                if torn:  # a row cut short by a kill: don't glue the next one to it
                    f.write("\n")
                f.write("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in new))
        return len(new)


def hunspell_oov(hunspell, dic):
    """words -> the ones hunspell does not know (`hunspell -l -d dic`). Without
    hunspell or a dictionary, nothing is out of dictionary."""
    def oov(words):
        if not hunspell or not dic or not words:
            return set()
        out = subprocess.run([hunspell, "-l", "-d", dic], input="\n".join(words), capture_output=True,
                             text=True, check=True, timeout=60)
        return set(out.stdout.split())
    return oov


def analyse(data_dir, vocab, oov, now_ms, redo=False):
    """Heuristic suspects for drafts new or re-uploaded since the last run
    (every draft with redo) into suspects.jsonl."""
    state_file = Path(data_dir) / "analysed.json"
    try:
        state = json.loads(state_file.read_text()) if state_file.exists() and not redo else {}
    except ValueError:
        state = {}
    drafts = added = 0
    for key, meta, segments in iter_drafts(data_dir):
        if not redo and state.get(key) == meta.get("received_ms"):
            continue
        try:
            found = heuristic_suspects(meta, segments, vocab, oov, now_ms)
        except (AttributeError, TypeError, ValueError, KeyError) as err:
            log(f"{key}: skipped, malformed ({type(err).__name__})")  # not retried until re-uploaded
            found = []
        added += append_unique(data_dir, "suspects.jsonl", found)
        state[key] = meta.get("received_ms")
        drafts += 1
    tmp = state_file.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state))
    os.replace(tmp, state_file)
    return {"drafts": drafts, "added": added}


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
    a = sub.add_parser("analyse")
    a.add_argument("--data-dir", required=True, type=Path)
    a.add_argument("--vocab", required=True, type=Path)
    a.add_argument("--hunspell")
    a.add_argument("--dict")
    a.add_argument("--all", action="store_true")
    m = sub.add_parser("mine")
    m.add_argument("--lab", required=True)
    m.add_argument("--sessions", required=True, type=Path)
    m.add_argument("--days", type=int, default=3)
    c = sub.add_parser("census")
    # Default: the hub's store (dictation-lab.nix dataDir), so `dictate-lab
    # census` works as typed on butternut.
    c.add_argument("--data-dir", type=Path,
                   default=Path(os.environ.get("DICTATE_LAB_DATA") or Path.home() / ".local/state/dictation/lab"))
    c.add_argument("--weeks", type=int, default=8)
    c.add_argument("--origin")
    c.add_argument("--tier", choices=["work", "personal"])
    c.add_argument("--lang")
    c.add_argument("--pairs", action="store_true", help="also print your repeated edits (transcript text)")
    args = ap.parse_args()
    if args.cmd == "serve":
        args.data_dir.mkdir(parents=True, exist_ok=True)
        server = make_server(args.data_dir, args.port, PeerCheck(tailscale_whois, tailscale_self_user()),
                             host=args.host)
        log(f"serving on {args.host}:{args.port}, data in {args.data_dir}")
        server.serve_forever()
    elif args.cmd == "analyse":
        vocab = json.loads(args.vocab.read_text())
        r = analyse(args.data_dir, vocab, hunspell_oov(args.hunspell, args.dict), int(time.time() * 1000),
                    redo=args.all)
        log(f"analysed {r['drafts']} drafts, {r['added']} new suspects")
    elif args.cmd == "census":
        scope = (args.data_dir, args.weeks, args.origin, args.tier, args.lang)
        print_census(census(*scope), pairs(args.data_dir, drafts=select(*scope)) if args.pairs else None)
    elif args.cmd == "mine":
        try:
            r = mine(args.lab.rstrip("/"), args.sessions, args.days, int(time.time() * 1000))
        except (OSError, ValueError, KeyError) as err:
            log(f"mine: lab unavailable ({type(err).__name__}); the next run retries")
            return
        log(f"mine: {r['drafts']} drafts, {r['matched']} matched a sent message, {r['added']} new suspects")
    else:
        n = prune(args.data_dir, args.audio_days, args.keep_lang, int(time.time() * 1000))
        log(f"pruned the audio of {n} drafts")


if __name__ == "__main__":
    main()
