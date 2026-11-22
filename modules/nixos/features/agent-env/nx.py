#!/usr/bin/env python3
"""nx: a store-first tool runner for agent sessions on metered links.

Usage:
    nx [-p ATTR] [--exact] PROG [ARGS...]
    nx --py PKG [PKG...] -- [PYTHON ARGS...]

Resolution order for `nx PROG`:
  1. PROG on PATH (skipped when `-p ATTR` is given) -> exec it, no nix calls.
  2. Resolve a nixpkgs attribute:
     a. `-p ATTR` given -> ATTR.
     b. else, if `nix eval --raw nixpkgs#<PROG>.outPath` succeeds -> PROG
        itself is the attribute (catches e.g. python3, openssl; the outPath
        from this call is reused below instead of evaluating twice).
     c. else `nix-locate --minimal --whole-name --at-root /bin/<PROG>`;
        strip the trailing `.<output>` component of each hit, drop any
        that still contain a dot (nested attribute sets), dedupe. Zero
        hits -> "no package provides"; several -> ambiguous, pick one
        with -p; exactly one -> use it.
  3. `nix eval --raw nixpkgs#<attr>.outPath`; if `<path>/bin/<PROG>` exists
     on disk, exec it directly (the pinned version is already present).
  4. Unless `--exact`: `nix eval --raw nixpkgs#<attr>.pname`, then scan
     $NX_STORE_DIR (default /nix/store) for `*-<pname>-<version>/bin/<PROG>`
     paths that `nix-store --check-validity` accepts, newest version wins.
     If found, run it (and say so: it is *not* the pinned version).
  5. `nix build --dry-run nixpkgs#<attr>`: parse the download size and the
     derivations that would need building. On a metered link, refuse (exit
     3) unless NX_FORCE=1, a real download under $NX_METERED_LIMIT_MB
     (default 50) is the only thing needed. Derivations whose name ends in
     `-env` don't count as a build for this gate. Otherwise:
     `nix shell nixpkgs#<attr> -c <PROG> ARGS...`.

`nx --py PKG... -- ARGS...` runs the same gate against a throwaway
`python3.withPackages` environment, then
`nix shell --impure --expr <expr> -c python3 ARGS...`.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

NX_FORCE_ENV = "NX_FORCE"
NX_METERED_LIMIT_ENV = "NX_METERED_LIMIT_MB"
NX_STORE_DIR_ENV = "NX_STORE_DIR"
DEFAULT_METERED_LIMIT_MB = 50
DEFAULT_STORE_DIR = "/nix/store"

_DOWNLOAD_RE = re.compile(r"\(([\d.]+)\s*(KiB|MiB|GiB)\s+download")
_UNIT_TO_MIB = {"KiB": 1.0 / 1024, "MiB": 1.0, "GiB": 1024.0}
_DRV_RE = re.compile(r"/nix/store/[0-9a-z]+-(.+)\.drv$")


def parse_dry_run(stderr: str) -> tuple[float, list[str]]:
    """Parse `nix build --dry-run` stderr into (download MiB, drv names)."""
    stderr = stderr or ""
    download_mib = 0.0
    m = _DOWNLOAD_RE.search(stderr)
    if m:
        download_mib = float(m.group(1)) * _UNIT_TO_MIB[m.group(2)]
    names = []
    for line in stderr.splitlines():
        dm = _DRV_RE.search(line.strip())
        if dm:
            names.append(dm.group(1))
    return download_mib, names


def _run(args, timeout=60, **kwargs):
    try:
        return subprocess.run(
            args, capture_output=True, text=True, timeout=timeout, **kwargs
        )
    except (OSError, subprocess.TimeoutExpired):
        return None


def _nix_eval_raw(expr: str):
    proc = _run(["nix", "eval", "--raw", expr])
    if proc is None or proc.returncode != 0:
        return None
    out = proc.stdout.strip()
    return out or None


def _try_outpath(attr: str):
    return _nix_eval_raw(f"nixpkgs#{attr}.outPath")


def _try_pname(attr: str):
    return _nix_eval_raw(f"nixpkgs#{attr}.pname")


def _locate_attr(prog: str) -> str:
    """Resolve a nixpkgs attribute for `prog` via nix-locate (ruling 2c).
    Exits the process on zero or ambiguous results."""
    proc = _run(
        ["nix-locate", "--minimal", "--whole-name", "--at-root", f"/bin/{prog}"]
    )
    lines = []
    if proc is not None and proc.returncode == 0:
        lines = [line.strip() for line in proc.stdout.splitlines() if line.strip()]

    candidates = []
    seen = set()
    for line in lines:
        token = line.split()[0]
        attr = token.rsplit(".", 1)[0] if "." in token else token
        if "." in attr:
            continue  # nested attribute set, not a top-level package
        if attr not in seen:
            seen.add(attr)
            candidates.append(attr)

    if not candidates:
        print(f"nx: no package provides {prog}", file=sys.stderr)
        sys.exit(2)
    if len(candidates) > 1:
        top = sorted(candidates, key=lambda a: (len(a), a))[:5]
        print(
            f"nx: {prog} is provided by several packages: {', '.join(top)}; "
            "pick one with -p",
            file=sys.stderr,
        )
        sys.exit(2)
    return candidates[0]


def _version_key(version: str):
    parts = [p for p in re.split(r"(\d+)", version) if p != ""]
    return tuple(int(p) if p.isdigit() else p for p in parts)


def _check_validity(path: Path) -> bool:
    proc = _run(["nix-store", "--check-validity", str(path)])
    return proc is not None and proc.returncode == 0


def _scan_store(store_dir: str, pname: str, prog: str):
    """Newest valid `<store_dir>/*-<pname>-<version>/bin/<prog>`, or None."""
    base = Path(store_dir)
    if not base.is_dir():
        return None
    pattern = re.compile(r"^.+-" + re.escape(pname) + r"-(\d.*)$")

    candidates = []
    try:
        entries = list(base.iterdir())
    except OSError:
        return None
    for entry in entries:
        m = pattern.match(entry.name)
        if not m or not entry.is_dir():
            continue
        binpath = entry / "bin" / prog
        if not binpath.is_file():
            continue
        if not _check_validity(entry):
            continue
        candidates.append((_version_key(m.group(1)), entry, binpath))

    if not candidates:
        return None
    candidates.sort(key=lambda c: c[0])
    _, entry, binpath = candidates[-1]
    return entry, binpath


def _agent_net_status() -> dict:
    """{"state", "connection"}; missing/failing/bad JSON -> unmetered."""
    fallback = {"state": "unmetered", "connection": None}
    proc = _run(["agent-net", "--json"], timeout=5)
    if proc is None or proc.returncode != 0:
        return fallback
    try:
        data = json.loads(proc.stdout)
    except ValueError:
        return fallback
    if not isinstance(data, dict) or "state" not in data:
        return fallback
    return data


def _dry_run(build_args: list):
    proc = _run(["nix", "build", "--dry-run", *build_args], timeout=300)
    if proc is None:
        return 0.0, []
    return parse_dry_run(proc.stderr)


def _metered_limit_mb() -> float:
    raw = os.environ.get(NX_METERED_LIMIT_ENV)
    if raw:
        try:
            return float(raw)
        except ValueError:
            pass
    return DEFAULT_METERED_LIMIT_MB


def _gate_and_run(label: str, download_mib: float, build_names: list, run_fn):
    """The metered-link gate shared by `nx PROG` and `nx --py`. Refuses
    (exit 3) when metered and not forced and there's a real build or the
    download exceeds the limit; otherwise reports the download (if any)
    and runs `run_fn()`."""
    force = os.environ.get(NX_FORCE_ENV) == "1"
    limit = _metered_limit_mb()
    net = _agent_net_status()
    metered = net.get("state") == "metered"
    connection = net.get("connection")

    real_builds = [n for n in build_names if not n.endswith("-env")]

    if metered and not force:
        if real_builds:
            print(
                f"nx: {label} needs building {', '.join(real_builds)}; "
                f"on a metered link ({connection}). "
                "Re-run with NX_FORCE=1 to build.",
                file=sys.stderr,
            )
            sys.exit(3)
        if download_mib > limit:
            print(
                f"nx: {label} needs {round(download_mib)} MiB download; "
                f"on a metered link ({connection}). "
                "Re-run with NX_FORCE=1 to fetch.",
                file=sys.stderr,
            )
            sys.exit(3)

    if download_mib > 0:
        print(
            f"nx: fetching {label} ({round(download_mib)} MiB download)",
            file=sys.stderr,
        )
    run_fn()


def _run_normal(prog: str, args: list, p_attr, exact: bool) -> int:
    store_dir = os.environ.get(NX_STORE_DIR_ENV, DEFAULT_STORE_DIR)
    outpath = None

    if p_attr is None:
        import shutil

        path_hit = shutil.which(prog)
        if path_hit:
            os.execvp(path_hit, [prog, *args])

        outpath = _try_outpath(prog)
        attr = prog if outpath is not None else _locate_attr(prog)
    else:
        attr = p_attr

    if outpath is None:
        outpath = _try_outpath(attr)

    if outpath:
        candidate = Path(outpath) / "bin" / prog
        if candidate.is_file():
            os.execvp(str(candidate), [str(candidate), *args])

    if not exact:
        pname = _try_pname(attr)
        if pname:
            hit = _scan_store(store_dir, pname, prog)
            if hit is not None:
                entry, binpath = hit
                print(
                    f"nx: using {entry.name} from the store "
                    "(not the pinned version)",
                    file=sys.stderr,
                )
                os.execvp(str(binpath), [str(binpath), *args])

    download_mib, build_names = _dry_run([f"nixpkgs#{attr}"])

    def run_shell():
        os.execvp("nix", ["nix", "shell", f"nixpkgs#{attr}", "-c", prog, *args])

    _gate_and_run(attr, download_mib, build_names, run_shell)
    return 0


def _py_expr(pkgs: list) -> str:
    return (
        '(builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem}'
        ".python3.withPackages (p: with p; [" + " ".join(pkgs) + "])"
    )


def _run_py(pkgs: list, py_args: list) -> int:
    expr = _py_expr(pkgs)
    download_mib, build_names = _dry_run(["--impure", "--expr", expr])

    def run_shell():
        os.execvp(
            "nix",
            ["nix", "shell", "--impure", "--expr", expr, "-c", "python3", *py_args],
        )

    label = f"python3 ({' '.join(pkgs)})"
    _gate_and_run(label, download_mib, build_names, run_shell)
    return 0


def _usage() -> int:
    print(
        "usage: nx [-p ATTR] [--exact] PROG [ARGS...]\n"
        "       nx --py PKG [PKG...] -- [PYTHON ARGS...]",
        file=sys.stderr,
    )
    return 2


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)

    if argv[:1] == ["--py"]:
        rest = argv[1:]
        if "--" in rest:
            idx = rest.index("--")
            pkgs, py_args = rest[:idx], rest[idx + 1 :]
        else:
            pkgs, py_args = rest, []
        if not pkgs:
            return _usage()
        return _run_py(pkgs, py_args)

    p_attr = None
    exact = False
    while argv and argv[0] in ("-p", "--exact"):
        if argv[0] == "-p":
            if len(argv) < 2:
                return _usage()
            p_attr = argv[1]
            argv = argv[2:]
        else:
            exact = True
            argv = argv[1:]

    if not argv:
        return _usage()

    prog, args = argv[0], argv[1:]
    return _run_normal(prog, args, p_attr, exact)


if __name__ == "__main__":
    sys.exit(main())
