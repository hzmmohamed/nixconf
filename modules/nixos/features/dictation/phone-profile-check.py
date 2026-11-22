"""Check a phone profile.json against the app's Kotlin model (Profile.kt).

    phone-profile-check.py <Profile.kt> <profile.json>

Reads the `data class` declarations of Profile.kt and walks the JSON from
`Profile`: every object must carry exactly the class's fields (the app
ignores unknown keys, so a misspelt key in Nix would silently fall back to
the app's default), with matching JSON types. Then the values the app
relies on: version 1, servers, four model files with hex sha256, and
fully qualified hosts in its own URLs (servers, model files, appUrl): the
phone's resolver may not search the tailnet domain, so a short name fails.
"""

import json
import re
import sys
from urllib.parse import urlparse

kotlin_path, profile_path = sys.argv[1:]
source = open(kotlin_path).read()
profile = json.load(open(profile_path))


def split_top(text, sep=","):
    parts, depth, cur = [], 0, ""
    for ch in text:
        if ch in "(<":
            depth += 1
        elif ch in ")>":
            depth -= 1
        if ch == sep and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return parts


def data_classes(src):
    classes = {}
    for m in re.finditer(r"data class (\w+)\(", src):
        depth, i = 1, m.end()
        while depth:
            depth += {"(": 1, ")": -1}.get(src[i], 0)
            i += 1
        fields = {}
        for param in split_top(src[m.end():i - 1]):
            p = re.match(r"\s*val (\w+):\s*([^=]+?)\s*(=.*)?$", param.strip(), re.S)
            if not p:
                sys.exit(f"cannot parse parameter of {m.group(1)}: {param!r}")
            fields[p.group(1)] = p.group(2).strip()
        classes[m.group(1)] = fields
    return classes


classes = data_classes(source)
errors = []
scalars = {
    "Int": int,
    "Long": int,
    "String": str,
    "Boolean": bool,
}


def check(value, typ, path):
    if typ.endswith("?"):
        if value is None:
            return
        typ = typ[:-1]
    lst = re.fullmatch(r"List<(.+)>", typ)
    if lst:
        if not isinstance(value, list):
            errors.append(f"{path}: expected a list ({typ})")
            return
        for i, v in enumerate(value):
            check(v, lst.group(1), f"{path}[{i}]")
    elif typ in scalars:
        ok = isinstance(value, scalars[typ]) and not (
            typ != "Boolean" and isinstance(value, bool)
        )
        if not ok:
            errors.append(f"{path}: expected {typ}, got {value!r}")
    elif typ in classes:
        if not isinstance(value, dict):
            errors.append(f"{path}: expected an object ({typ})")
            return
        fields = classes[typ]
        for k in sorted(set(value) - set(fields)):
            errors.append(f"{path}.{k}: not a field of {typ} (Profile.kt)")
        for k in sorted(set(fields) - set(value)):
            errors.append(f"{path}.{k}: missing ({typ} field)")
        for k in set(fields) & set(value):
            check(value[k], fields[k], f"{path}.{k}")
    else:
        errors.append(f"{path}: unknown Kotlin type {typ}")


if "Profile" not in classes:
    sys.exit("no data class Profile in " + kotlin_path)
check(profile, "Profile", "$")

version = re.search(r"const val PROFILE_VERSION = (\d+)", source)
if not version or profile.get("version") != int(version.group(1)):
    errors.append("$.version: does not match PROFILE_VERSION in Profile.kt")
if not profile.get("servers"):
    errors.append("$.servers: empty")
if profile.get("defaultLanguage") not in profile.get("languages", []):
    errors.append("$.defaultLanguage: not in languages")
model = profile.get("localModel") or {}
files = model.get("files", [])
if len(files) != 4:
    errors.append(f"$.localModel.files: {len(files)} files, expected 4")
hexes = [f.get("sha256", "") for f in files] + [
    (model.get("archive") or {}).get("sha256", "")
]
for h in hexes:
    if not re.fullmatch(r"[0-9a-f]{64}", str(h)):
        errors.append(f"sha256 {h!r} is not 64 hex digits")
for f in files:
    if not isinstance(f.get("size"), int) or f["size"] <= 0:
        errors.append(f"$.localModel.files {f.get('name')}: size {f.get('size')}")

own_urls = [("$.servers", u) for u in profile.get("servers", [])]
own_urls += [(f"$.localModel.files {f.get('name')}", f.get("url", "")) for f in files]
own_urls.append(("$.appUrl", profile.get("appUrl") or ""))
for where, url in own_urls:
    host = urlparse(str(url)).hostname or ""
    if "." not in host:
        errors.append(f"{where}: {url!r} has no fully qualified host")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print("phone profile matches Profile.kt:", ", ".join(sorted(classes)))
