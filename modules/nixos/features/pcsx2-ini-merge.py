"""Merge a few keys into PCSX2's PCSX2.ini without clobbering the rest.

PCSX2 rewrites its ini on every settings change, so it can't be a read-only
store symlink. This edits it line by line (keeping comments, ordering and
PCSX2's multi-value keys, e.g. several bindings for one pad button).

usage: pcsx2-ini-merge INI SPEC.json

SPEC = {
  "enforce":  {section: {key: value}},   # always set (declarative keys)
  "default":  {section: {key: value}},   # set only when the key is absent
  "bindings": {section: {key: value}},   # set only when no value in the
                                         # section is an SDL- binding yet
                                         # (seed once; user remaps survive)
}
"""

import json
import os
import re
import sys
import tempfile

SECTION_RE = re.compile(r"^\s*\[(?P<name>[^\]]+)\]\s*$")
KEY_RE = re.compile(r"^\s*(?P<key>[^=;#\[]+?)\s*=\s*(?P<value>.*?)\s*$")


class Ini:
    def __init__(self, text):
        self.lines = text.splitlines()

    def _bounds(self, section):
        """(header index, end index) of a section, or None."""
        start = None
        for i, line in enumerate(self.lines):
            m = SECTION_RE.match(line)
            if not m:
                continue
            if start is not None:
                return start, i
            if m.group("name") == section:
                start = i
        return (start, len(self.lines)) if start is not None else None

    def values(self, section):
        b = self._bounds(section)
        if b is None:
            return []
        out = []
        for line in self.lines[b[0] + 1:b[1]]:
            m = KEY_RE.match(line)
            if m:
                out.append((m.group("key"), m.group("value")))
        return out

    def has(self, section, key):
        return any(k == key for k, _ in self.values(section))

    def set(self, section, key, value):
        line = f"{key} = {value}"
        b = self._bounds(section)
        if b is None:
            if self.lines and self.lines[-1].strip():
                self.lines.append("")
            self.lines += [f"[{section}]", line]
            return
        start, end = b
        hits = [
            i for i in range(start + 1, end)
            if (m := KEY_RE.match(self.lines[i])) and m.group("key") == key
        ]
        if hits:
            self.lines[hits[0]] = line
            for i in reversed(hits[1:]):
                del self.lines[i]
            return
        # Append after the section's last non-blank line.
        pos = end
        while pos > start + 1 and not self.lines[pos - 1].strip():
            pos -= 1
        self.lines.insert(pos, line)

    def text(self):
        return "\n".join(self.lines) + "\n"


def fmt(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def main():
    path, spec_path = sys.argv[1], sys.argv[2]
    with open(spec_path) as f:
        spec = json.load(f)

    try:
        with open(path) as f:
            ini = Ini(f.read())
    except FileNotFoundError:
        ini = Ini("")

    for section, kv in spec.get("enforce", {}).items():
        for key, value in kv.items():
            ini.set(section, key, fmt(value))

    for section, kv in spec.get("default", {}).items():
        for key, value in kv.items():
            if not ini.has(section, key):
                ini.set(section, key, fmt(value))

    for section, kv in spec.get("bindings", {}).items():
        if any(v.startswith("SDL-") for _, v in ini.values(section)):
            continue
        for key, value in kv.items():
            ini.set(section, key, fmt(value))

    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".PCSX2.ini.")
    with os.fdopen(fd, "w") as f:
        f.write(ini.text())
    os.replace(tmp, path)


if __name__ == "__main__":
    main()
