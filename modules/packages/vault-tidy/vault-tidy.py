"""vault-tidy: sort and audit the KeePassXC vault with a local model.

  vault-tidy scan  [--db PATH] [--keyfile PATH] [--no-model] ...
  vault-tidy apply [RUN_DIR]   [--db PATH] [--keyfile PATH]

scan reads the vault (never writes it) and writes a run directory under
$XDG_STATE_HOME/vault-tidy/<timestamp>/:

  review.md         the checklist: every proposed change is a checkbox.
                    Confident ones are pre-checked; the rest, plus anything
                    only you can answer, are unchecked. Edit freely.
  changes.json      the same proposals, machine-readable (apply reads it)
  vault.preview.kdbx  the vault with the pre-checked changes, to browse in
                    KeePassXC (same master password)

apply re-opens the vault, checks it hasn't changed since the scan, applies
exactly the checked boxes, keeps the old file as vault.before.kdbx in the run
directory and replaces the vault in place (Syncthing then syncs it).

Privacy: the model (an OpenAI-compatible endpoint, by default llama-swap on
peacelily over the tailnet) only ever sees title, URL, username, group and
tags. Passwords, notes, TOTP secrets and attachments stay in this process;
the password checks (weak, reused, empty) run here, without a model.
"""

import argparse
import datetime as dt
import getpass
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

from pykeepass import PyKeePass
from pykeepass import icons
from pykeepass.exceptions import CredentialsError

# Top-level groups the model may sort into, with their KeePass icons.
GROUPS = {
    "Personal": icons.Home,
    "Work": icons.BUSINESS_CARD,
    "Finance": icons.Homebanking,
    "Government & IDs": icons.Identity,
    "Shopping": icons.Money,
    "Travel": icons.GLOBE,
    "Health": icons.Info,
    "Utilities & Telecom": icons.Energy,
    "Email & Messaging": icons.EMail,
    "Social": icons.GLOBE_STAR,
    "Media & Entertainment": icons.Digicam,
    "Dev & Infra": icons.Console,
    "Education": icons.Book,
    "Archive": icons.Archive,
}
ARCHIVE = "Archive"

DEFAULT_ENDPOINT = os.environ.get("VAULT_TIDY_ENDPOINT", "http://peacelily:9292/v1")
DEFAULT_MODEL = os.environ.get("VAULT_TIDY_MODEL", "qwen3.5:9b-nothinker")
BATCH = 15

SYSTEM_PROMPT = f"""You sort password-manager entries. For each entry you get
id, title, url, username, current group path and tags. Never invent data you
cannot infer from those fields.

For each entry return:
- group: exactly one of {json.dumps(list(GROUPS))}. Work accounts (company
  domains, work email usernames, corporate SaaS used for a job) go to "Work".
- title: a short clean name for the service, e.g. "GitHub", "Deutsche Bahn",
  "AWS (work)". Keep the original if it is already clean. Keep qualifiers that
  tell two accounts apart (personal/work, a username hint).
- url: only when the entry has no url and the service is unambiguous: its
  login page origin, e.g. "https://github.com". Otherwise "".
- critical: true for accounts whose compromise compromises others: primary
  email, password manager, banks/brokers, domain registrars, cloud provider
  root/admin accounts, government identity.
- status: "possibly_dead" if the service is known to be shut down or the
  entry looks like a throwaway/test account; "active" if clearly a live
  service; "unknown" otherwise.
- confidence: "high" only when the group and title are obvious from the
  fields; "medium" or "low" otherwise.
- reason: at most 12 words, why.
Return JSON matching the schema, one item per input id."""

RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "entries": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "integer"},
                    "group": {"type": "string", "enum": list(GROUPS)},
                    "title": {"type": "string"},
                    "url": {"type": "string"},
                    "critical": {"type": "boolean"},
                    "status": {"type": "string", "enum": ["active", "possibly_dead", "unknown"]},
                    "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
                    "reason": {"type": "string"},
                },
                "required": ["id", "group", "title", "url", "critical", "status", "confidence", "reason"],
            },
        }
    },
    "required": ["entries"],
}


# --- vault access -----------------------------------------------------------


def default_db():
    return Path(os.environ.get("VAULT_TIDY_DB", Path.home() / "Vault" / "vault.kdbx"))


def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(base) / "vault-tidy"


def read_password():
    if not sys.stdin.isatty():
        return sys.stdin.readline().rstrip("\n")
    return getpass.getpass("Master password: ")


def open_vault(db, keyfile, password):
    try:
        return PyKeePass(str(db), password=password, keyfile=str(keyfile) if keyfile else None)
    except CredentialsError:
        sys.exit("Wrong master password or key file (pass --keyfile if the vault uses one).")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def live_entries(kp):
    """Entries outside the recycle bin, excluding history copies."""
    rb = kp.recyclebin_group
    out = []
    for e in kp.entries:
        if e.is_a_history_entry:
            continue
        g = e.group
        in_bin = False
        while rb is not None and g is not None:
            if g.uuid == rb.uuid:
                in_bin = True
                break
            g = g.parentgroup
        if not in_bin:
            out.append(e)
    return out


def group_path(e):
    return "/".join(e.group.path) if e.group.path else ""


# --- local checks (no model) -------------------------------------------------


def domain_of(url):
    if not url:
        return ""
    if "://" not in url:
        url = "https://" + url
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    host = host.removeprefix("www.")
    parts = host.split(".")
    # Registrable domain, roughly: keep 3 labels for co.uk-style suffixes.
    if len(parts) >= 3 and len(parts[-1]) == 2 and parts[-2] in {"co", "com", "org", "net", "gov", "ac", "edu"}:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:])


def entropy_bits(pw):
    pools = [
        (r"[a-z]", 26),
        (r"[A-Z]", 26),
        (r"[0-9]", 10),
        (r"[^a-zA-Z0-9]", 33),
    ]
    size = sum(n for rx, n in pools if re.search(rx, pw))
    return len(pw) * math.log2(size) if size else 0.0


def health_flags(entries):
    """Informational findings; fixing them means changing passwords at the site."""
    flags = {"empty": [], "weak": [], "reused": [], "expired": [], "duplicates": []}
    by_hash = {}
    now = dt.datetime.now(dt.timezone.utc)
    for e in entries:
        pw = e.password or ""
        label = describe(e)
        if not pw:
            flags["empty"].append(label)
        else:
            if len(pw) < 10 or entropy_bits(pw) < 60:
                flags["weak"].append(label)
            by_hash.setdefault(hashlib.sha256(pw.encode()).hexdigest(), []).append(label)
        if e.expires and e.expiry_time and e.expiry_time < now:
            flags["expired"].append(label)
    flags["reused"] = [labels for labels in by_hash.values() if len(labels) > 1]

    by_login = {}
    for e in entries:
        d = domain_of(e.url)
        if d:
            by_login.setdefault((d, (e.username or "").strip().lower()), []).append(e)
    flags["duplicates"] = [group for group in by_login.values() if len(group) > 1]
    return flags


def describe(e):
    bits = [e.title or "(untitled)"]
    if e.username:
        bits.append(f"<{e.username}>")
    g = group_path(e)
    if g:
        bits.append(f"in {g}")
    return " ".join(bits)


# --- model ------------------------------------------------------------------


def http_json(url, payload=None, timeout=30):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def check_endpoint(endpoint, model):
    try:
        models = http_json(f"{endpoint}/models", timeout=10)
    except (urllib.error.URLError, OSError) as err:
        sys.exit(f"Model endpoint {endpoint} unreachable ({err}).\n"
                 "Is peacelily on and llama-swap running? Or run with --no-model "
                 "for the password checks only.")
    ids = {m.get("id") for m in models.get("data", [])}
    if ids and model not in ids:
        sys.exit(f"Model {model!r} not served by {endpoint}; available: {', '.join(sorted(ids))}")


def classify(entries, endpoint, model):
    """Index → model suggestion. Only title/url/username/group/tags are sent."""
    out = {}
    for start in range(0, len(entries), BATCH):
        batch = entries[start:start + BATCH]
        items = [
            {
                "id": start + i,
                "title": e.title or "",
                "url": e.url or "",
                "username": e.username or "",
                "group": group_path(e),
                "tags": e.tags or [],
            }
            for i, e in enumerate(batch)
        ]
        payload = {
            "model": model,
            "temperature": 0,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": json.dumps({"entries": items}, ensure_ascii=False)},
            ],
            "response_format": {
                "type": "json_schema",
                "json_schema": {"name": "entries", "schema": RESPONSE_SCHEMA},
            },
        }
        print(f"  model: entries {start + 1}–{start + len(batch)} of {len(entries)}", file=sys.stderr)
        # llama-swap may cold-start the model: allow its health-check window.
        resp = http_json(f"{endpoint}/chat/completions", payload, timeout=900)
        content = resp["choices"][0]["message"]["content"]
        try:
            parsed = json.loads(content)
        except json.JSONDecodeError:
            m = re.search(r"\{.*\}", content, re.S)
            parsed = json.loads(m.group(0)) if m else {"entries": []}
        for s in parsed.get("entries", []):
            if isinstance(s.get("id"), int) and start <= s["id"] < start + len(batch) and s.get("group") in GROUPS:
                out[s["id"]] = s
    return out


# --- proposals --------------------------------------------------------------


def propose(entries, suggestions):
    """Turn model output into change records. Rules:
    - group/title/tags: pre-checked only at high confidence, and a move out
      of a group that is already one of GROUPS is never pre-checked;
    - url: never pre-checked (a wrong URL autofills on the wrong site);
    - archive (possibly dead): never pre-checked;
    - 2fa tag: deterministic (entry has TOTP), pre-checked."""
    changes = []

    def add(e, kind, old, new, checked, reason):
        changes.append({
            "id": f"{e.uuid}:{kind}",
            "uuid": str(e.uuid),
            "entry": describe(e),
            "kind": kind,
            "old": old,
            "new": new,
            "checked": checked,
            "reason": reason,
        })

    for i, e in enumerate(entries):
        tags = list(e.tags or [])
        if e.otp and "2fa" not in tags:
            add(e, "tag", None, "2fa", True, "entry has a TOTP secret")
        s = suggestions.get(i)
        if not s:
            continue
        high = s["confidence"] == "high"
        reason = s.get("reason", "")
        current_top = e.group.path[0] if e.group.path else ""

        if s["status"] == "possibly_dead":
            if current_top != ARCHIVE:
                add(e, "group", group_path(e), ARCHIVE, False, f"possibly dead: {reason}")
        elif s["group"] != current_top:
            sorted_already = current_top in GROUPS
            add(e, "group", group_path(e), s["group"], high and not sorted_already, reason)

        new_title = s["title"].strip()
        if new_title and new_title != (e.title or "").strip():
            add(e, "title", e.title or "", new_title, high, reason)

        if s["url"] and not e.url:
            add(e, "url", "", s["url"].strip(), False, "suggested by the model: check it is the real site")

        if s["critical"] and "critical" not in tags:
            add(e, "tag", None, "critical", high, reason)
    return changes


def apply_changes(kp, changes):
    """Apply the checked changes; returns how many were applied."""
    groups = {}

    def top_group(name):
        if name not in groups:
            g = kp.find_groups(name=name, group=kp.root_group, recursive=False, first=True)
            groups[name] = g or kp.add_group(kp.root_group, name, icon=GROUPS.get(name))
        return groups[name]

    n = 0
    for c in changes:
        if not c["checked"]:
            continue
        e = kp.find_entries(uuid=uuid.UUID(c["uuid"]), first=True)
        if e is None:
            print(f"  skipped (entry gone): {c['entry']}", file=sys.stderr)
            continue
        if c["kind"] == "group":
            kp.move_entry(e, top_group(c["new"]))
        elif c["kind"] == "title":
            e.title = c["new"]
        elif c["kind"] == "url":
            e.url = c["new"]
        elif c["kind"] == "tag":
            e.tags = sorted(set(e.tags or []) | {c["new"]})
        n += 1
    return n


# --- review file ------------------------------------------------------------

LINE_ID = re.compile(r"^\s*- \[([ xX])\] .*<!-- id:(\S+) -->\s*$")


def change_line(c):
    box = "x" if c["checked"] else " "
    if c["kind"] == "group":
        what = f"move to **{c['new']}**" + (f" (now in {c['old']})" if c["old"] else "")
    elif c["kind"] == "title":
        what = f"rename to **{c['new']}**"
    elif c["kind"] == "url":
        what = f"set URL to `{c['new']}`"
    else:
        what = f"add tag `{c['new']}`"
    reason = f" — {c['reason']}" if c["reason"] else ""
    return f"- [{box}] {c['entry']}: {what}{reason} <!-- id:{c['id']} -->"


def write_review(path, db, changes, flags, used_model):
    sections = [
        ("Needs your decision", lambda c: not c["checked"] and c["kind"] != "url"
         and not (c["kind"] == "group" and c["new"] == ARCHIVE)),
        ("Possibly dead: move to Archive?", lambda c: c["kind"] == "group" and c["new"] == ARCHIVE),
        ("Suggested URLs (check each is the real login site)", lambda c: c["kind"] == "url"),
        ("Pre-approved (high confidence; uncheck to skip)", lambda c: c["checked"]),
    ]
    out = [
        f"# Vault review — {dt.date.today().isoformat()}",
        "",
        f"Vault: `{db}`",
        "",
        "Check the boxes you want, uncheck the ones you don't, then run",
        "`vault-tidy apply` (KeePassXC closed on every device first).",
        "Only checked boxes are applied; everything else stays as it is.",
        "",
    ]
    if not used_model:
        out += ["_Model step skipped (--no-model): password checks only._", ""]
    for title, pred in sections:
        items = [c for c in changes if pred(c)]
        if items:
            out += [f"## {title} ({len(items)})", ""] + [change_line(c) for c in items] + [""]

    out += ["## Password health (fix in KeePassXC, then at the site)", ""]
    any_flag = False
    for key, title in [("empty", "Empty password"), ("weak", "Weak password"), ("expired", "Expired")]:
        if flags[key]:
            any_flag = True
            out += [f"### {title} ({len(flags[key])})", ""] + [f"- {x}" for x in flags[key]] + [""]
    if flags["reused"]:
        any_flag = True
        out += [f"### Same password on several entries ({len(flags['reused'])} sets)", ""]
        out += [f"- {' · '.join(g)}" for g in flags["reused"]] + [""]
    if flags["duplicates"]:
        any_flag = True
        out += [f"### Possible duplicates: same site and username ({len(flags['duplicates'])})", ""]
        out += [f"- {' · '.join(describe(e) for e in g)}" for g in flags["duplicates"]] + [""]
    if not any_flag:
        out += ["Nothing found.", ""]
    out += [
        "Breach check (Have I Been Pwned) isn't done here: KeePassXC's",
        "Database → Reports → HIBP does it with hash prefixes only.",
        "",
    ]
    path.write_text("\n".join(out))


def read_review(path, changes):
    marks = {}
    for line in path.read_text().splitlines():
        m = LINE_ID.match(line)
        if m:
            marks[m.group(2)] = m.group(1) != " "
    for c in changes:
        c["checked"] = marks.get(c["id"], False)
    return changes


# --- commands ---------------------------------------------------------------


def cmd_scan(args):
    db = Path(args.db).expanduser()
    if not db.exists():
        sys.exit(f"No vault at {db} (pass --db).")
    if not args.no_model:
        check_endpoint(args.endpoint, args.model)

    kp = open_vault(db, args.keyfile, read_password())
    entries = live_entries(kp)
    print(f"{len(entries)} entries in {db}", file=sys.stderr)

    suggestions = {} if args.no_model else classify(entries, args.endpoint, args.model)
    changes = propose(entries, suggestions)
    flags = health_flags(entries)

    run = state_dir() / dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    run.mkdir(parents=True, mode=0o700)
    (run / "changes.json").write_text(json.dumps({
        "db": str(db),
        "sha256": sha256(db),
        "model": None if args.no_model else args.model,
        "changes": changes,
    }, indent=2, ensure_ascii=False))
    write_review(run / "review.md", db, changes, flags, not args.no_model)

    applied = apply_changes(kp, changes)
    kp.save(filename=str(run / "vault.preview.kdbx"))
    for f in run.iterdir():
        f.chmod(0o600)

    latest = state_dir() / "latest"
    if latest.is_symlink() or latest.exists():
        latest.unlink()
    latest.symlink_to(run.name)

    undecided = sum(1 for c in changes if not c["checked"])
    print(f"\n{len(changes)} proposals: {applied} pre-approved, {undecided} need you.")
    print(f"Review:  {run / 'review.md'}")
    print(f"Preview: {run / 'vault.preview.kdbx'} (pre-approved changes applied)")
    print("Then:    vault-tidy apply")


def keepassxc_running():
    return subprocess.run(["pgrep", "-x", "keepassxc"], capture_output=True).returncode == 0


def cmd_apply(args):
    run = Path(args.run_dir).expanduser() if args.run_dir else (state_dir() / "latest").resolve()
    meta = json.loads((run / "changes.json").read_text())
    db = Path(args.db).expanduser() if args.db else Path(meta["db"])

    if keepassxc_running():
        sys.exit("KeePassXC is running here: quit it (tray → Quit) so it can't overwrite the change.\n"
                 "Also close the vault on your other devices and the phone.")
    if sha256(db) != meta["sha256"]:
        sys.exit(f"{db} changed since this scan (an edit or a sync). Run vault-tidy scan again.")

    changes = read_review(run / "review.md", meta["changes"])
    chosen = sum(c["checked"] for c in changes)
    if chosen == 0:
        sys.exit("No boxes checked in review.md: nothing to do.")

    kp = open_vault(db, args.keyfile, read_password())
    applied = apply_changes(kp, changes)

    shutil.copy2(db, run / "vault.before.kdbx")
    tmp = db.with_name(f".{db.name}.vault-tidy")
    kp.save(filename=str(tmp))
    os.chmod(tmp, os.stat(db).st_mode & 0o777)
    os.replace(tmp, db)
    print(f"Applied {applied} changes to {db}.")
    print(f"Previous version: {run / 'vault.before.kdbx'}")


def main():
    p = argparse.ArgumentParser(prog="vault-tidy", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scan", help="analyse the vault and write review.md (vault untouched)")
    s.add_argument("--db", default=str(default_db()))
    s.add_argument("--keyfile")
    s.add_argument("--endpoint", default=DEFAULT_ENDPOINT, help="OpenAI-compatible base URL")
    s.add_argument("--model", default=DEFAULT_MODEL)
    s.add_argument("--no-model", action="store_true", help="password checks only")
    s.set_defaults(func=cmd_scan)

    a = sub.add_parser("apply", help="apply the checked boxes of a review to the vault")
    a.add_argument("run_dir", nargs="?", help="default: the latest scan")
    a.add_argument("--db", help="default: the vault the scan read")
    a.add_argument("--keyfile")
    a.set_defaults(func=cmd_apply)

    args = p.parse_args()
    args.endpoint = getattr(args, "endpoint", DEFAULT_ENDPOINT).rstrip("/")
    args.func(args)


if __name__ == "__main__":
    main()
