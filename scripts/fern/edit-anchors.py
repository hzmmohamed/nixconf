"""Deterministic edits at the `# fern-*` anchors (used by scripts/fern/enroll.sh).

    python3 edit-anchors.py <repo> <ts4> <host-key> <age-recipient>

Edits modules/hosts-registry.nix (ts4, hostKey) and .sops.yaml (the &fern key
and `- *fern` recipients). Idempotent: re-running with new values (host key
changed after an instance replacement) rewrites the same lines. Every anchor
must match exactly once, or nothing is written.
"""

import re
import sys
from pathlib import Path

repo, ts4, host_key, age = sys.argv[1:5]

if not re.fullmatch(r"100\.\d{1,3}\.\d{1,3}\.\d{1,3}", ts4):
    sys.exit(f"not a tailnet IPv4: {ts4!r}")
if not re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/]+=*", host_key):
    sys.exit("not an ssh-ed25519 public key")
if not re.fullmatch(r"age1[0-9a-z]{58}", age):
    sys.exit("not an age recipient")


def sub_once(text, pattern, repl, what, count_min=1, count_max=1):
    new, n = re.subn(pattern, repl, text, flags=re.M)
    if not count_min <= n <= count_max:
        sys.exit(f"anchor {what}: expected {count_min}..{count_max} match(es), found {n}")
    return new


reg = Path(repo, "modules/hosts-registry.nix")
r = reg.read_text()
r = sub_once(
    r,
    r'^(\s*)ts4 = (?:null|"[0-9.]+");( # fern-ts4.*)$',
    lambda m: f'{m[1]}ts4 = "{ts4}";{m[2]}',
    "fern-ts4",
)
r = sub_once(
    r,
    r'^(\s*)hostKey = (?:null|"[^"]*");( # fern-hostKey.*)$',
    lambda m: f'{m[1]}hostKey = "{host_key}";{m[2]}',
    "fern-hostKey",
)

sops = Path(repo, ".sops.yaml")
s = sops.read_text()
s = sub_once(
    s,
    r"^(\s*)(?:- &fern age1[0-9a-z]+ +)?# fern-age-key\b.*$",
    lambda m: f"{m[1]}- &fern {age} # fern-age-key (scripts/fern/enroll.sh)",
    "fern-age-key",
)
# Unconverted markers become recipients; already converted ones stay.
s, _ = re.subn(r"^(\s*)# fern-recipient$", r"\1- *fern # fern-recipient", s, flags=re.M)
if "- *fern # fern-recipient" not in s:
    sys.exit("anchor fern-recipient: none found in .sops.yaml")

reg.write_text(r)
sops.write_text(s)
print("edited modules/hosts-registry.nix and .sops.yaml")
