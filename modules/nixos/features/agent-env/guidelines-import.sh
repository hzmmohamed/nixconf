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
# Never rewrites or removes anything else in the file.
set -euo pipefail

IMPORT_LINE='@~/.config/agents/guidelines.md'
# Tolerates leading/trailing whitespace on an otherwise-matching existing
# line (e.g. a user's editor trimmed or padded it) so it isn't treated as
# missing and duplicated.
IMPORT_LINE_RE='[[:space:]]*@~/\.config/agents/guidelines\.md[[:space:]]*'

for dir in "$@"; do
  target_dir="$HOME/$dir"
  mkdir -p "$target_dir"
  file="$target_dir/CLAUDE.md"

  if [ ! -s "$file" ]; then
    printf '%s\n' "$IMPORT_LINE" >"$file"
    continue
  fi

  if grep -qxE "$IMPORT_LINE_RE" "$file"; then
    continue
  fi

  if [ "$(tail -c1 "$file")" != "" ]; then
    printf '\n' >>"$file"
  fi
  printf '\n%s\n' "$IMPORT_LINE" >>"$file"
done
