#!/usr/bin/env bash
# Usage: guidelines-import.sh DIR...
#
# For every DIR (a Claude config dir relative to $HOME, e.g. ".claude"),
# ensures $HOME/DIR/CLAUDE.md contains the import line exactly once:
#   - missing file: create it holding just the import line.
#   - existing file without the line: append it, after a blank line when
#     the file already has content (adding a trailing newline first if it
#     doesn't end in one).
#   - file already has the line: leave it untouched.
#   - CLAUDE.md is a symlink (e.g. managed by another tool / the store) or
#     isn't writable, or DIR can't be created: warn on stderr and skip it.
# Never rewrites or removes anything else in the file. Per-file problems
# never fail the script (it runs during Home Manager activation, where a
# non-zero exit would abort the whole switch).
set -euo pipefail

warn() {
  printf 'agent-guidelines-import: %s\n' "$*" >&2
}

IMPORT_LINE='@~/.config/agents/guidelines.md'
# Tolerates leading/trailing whitespace on an otherwise-matching existing
# line (e.g. a user's editor trimmed or padded it) so it isn't treated as
# missing and duplicated.
IMPORT_LINE_RE='[[:space:]]*@~/\.config/agents/guidelines\.md[[:space:]]*'

import_into() {
  local dir="$1"
  local target_dir="$HOME/$dir"
  if ! mkdir -p "$target_dir" 2>/dev/null; then
    warn "can't create $target_dir; skipping (add '$IMPORT_LINE' to its CLAUDE.md yourself)"
    return 0
  fi
  local file="$target_dir/CLAUDE.md"

  if [ -L "$file" ] || { [ -e "$file" ] && [ ! -w "$file" ]; }; then
    if [ -r "$file" ] && grep -qxE "$IMPORT_LINE_RE" "$file"; then
      return 0
    fi
    warn "$file is a symlink or read-only; not touching it (add '$IMPORT_LINE' yourself)"
    return 0
  fi

  if [ ! -s "$file" ]; then
    printf '%s\n' "$IMPORT_LINE" >"$file"
    return 0
  fi

  if grep -qxE "$IMPORT_LINE_RE" "$file"; then
    return 0
  fi

  if [ "$(tail -c1 "$file")" != "" ]; then
    printf '\n' >>"$file"
  fi
  printf '\n%s\n' "$IMPORT_LINE" >>"$file"
}

for dir in "$@"; do
  # `|| warn`: an unexpected failure for one account (disk full, a race)
  # still mustn't abort activation or skip the others.
  import_into "$dir" || warn "couldn't update $HOME/$dir/CLAUDE.md"
done
