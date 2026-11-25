#!/usr/bin/env bash
# Usage: prune-worktrees.sh [--apply]
#
# Lists local branches merged into main (PRs merge with merge commits) and the
# worktree each one is checked out in. Dry run by default; --apply runs
# `git worktree remove <path>` and `git branch -d <branch>` for each.
#
# Never touches main or the current branch. Skips a branch whose worktree is
# dirty, locked or the main checkout, and a fresh branch: tip on main's
# first-parent line and no commit/rebase in its reflog (`--merged` lists a
# branch that has nothing to merge yet too).
set -euo pipefail

base=main
apply=0
case "${1:-}" in
  --apply) apply=1 ;;
  "") ;;
  *)
    echo "usage: $0 [--apply]" >&2
    exit 2
    ;;
esac

common=$(git rev-parse --path-format=absolute --git-common-dir)
main_root=$(dirname "$common")
current=$(git branch --show-current)
base_sha=$(git rev-parse --verify "$base^{commit}")
echo "base: $base ($(git rev-parse --short "$base_sha"))"

declare -A first_parent wt_of locked
while read -r c; do first_parent[$c]=1; done < <(git rev-list --first-parent "$base_sha")

# branch -> worktree path, from `git worktree list --porcelain` blocks.
path=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*) path=${line#worktree } ;;
    "branch refs/heads/"*) wt_of[${line#branch refs/heads/}]=$path ;;
    locked*) locked[$path]=1 ;;
  esac
done < <(git worktree list --porcelain)

n=0
skipped=0
while IFS= read -r br; do
  [ "$br" = "$base" ] || [ "$br" = "$current" ] && continue
  wt=${wt_of[$br]:-}
  where=${wt:+worktree $wt}
  where=${where:-no worktree}
  # On main's first-parent line: fast-forwarded if its reflog shows work of
  # its own, else a fresh branch with nothing to merge yet.
  if [ -n "${first_parent[$(git rev-parse "refs/heads/$br")]:-}" ] &&
    ! grep -qE '^(commit|rebase|merge|cherry-pick)' <<<"$(git reflog show --format=%gs "refs/heads/$br" 2>/dev/null)"; then
    printf 'skip    %-40s no commits of its own (fresh branch)\n' "$br"
    skipped=$((skipped + 1))
    continue
  fi
  if [ -n "$wt" ]; then
    reason=""
    if [ "$wt" = "$main_root" ]; then
      reason="checked out in the main checkout"
    elif [ -n "${locked[$wt]:-}" ]; then
      reason="worktree $wt is locked"
    elif [ -d "$wt" ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      reason="worktree $wt is dirty"
    fi
    if [ -n "$reason" ]; then
      printf 'skip    %-40s %s\n' "$br" "$reason"
      skipped=$((skipped + 1))
      continue
    fi
  fi
  printf 'remove  %-40s %s\n' "$br" "$where"
  n=$((n + 1))
  [ "$apply" = 1 ] || continue
  if [ -n "$wt" ]; then
    if [ -d "$wt" ]; then
      git worktree remove "$wt" || {
        echo "  failed to remove $wt; keeping $br" >&2
        continue
      }
    else
      git worktree prune
    fi
  fi
  # From the main checkout when it is on main: `-d` checks merged-ness
  # against HEAD, which in a stale thread worktree may be behind main.
  if [ "$(git -C "$main_root" branch --show-current)" = "$base" ]; then
    git -C "$main_root" branch -d "$br"
  else
    git branch -d "$br"
  fi
done < <(git branch --merged "$base_sha" --format='%(refname:short)')

if [ "$apply" = 1 ]; then
  echo "removed $n branch(es) and their worktrees; skipped $skipped"
else
  echo "dry run: $n to remove, $skipped skipped; pass --apply to remove them"
fi
