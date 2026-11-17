#!/usr/bin/env bash
# scrub-unpushed-history.sh — rewrite ONLY the commits not yet on GitHub
# (origin/main..main), replacing sensitive strings in file contents and commit
# messages, so `main` can be pushed to the public repo.
#
# Why: early docs commits carried AWS identifiers (an account ID, bucket
# names), redacted in later commits. Redacting the tip is not enough: the
# old blobs are still in history and a push would publish them.
#
# The strings live in a LOCAL, gitignored file (never commit it):
#   scripts/repo/scrub-strings.local   (override: SCRUB_STRINGS=<file>)
# One literal per line, optionally with its replacement (git filter-repo
# --replace-text syntax; only literals are supported here):
#   123456789012==>ACCOUNT_ID
#   my-secret-bucket==>BUCKET
#   some-literal                 (→ ***REMOVED***)
# Blank lines and lines starting with # are ignored.
#
# Usage (run on the machine whose `origin` is GitHub, i.e. butternut):
#   bash scripts/repo/scrub-unpushed-history.sh            # dry run (default)
#   bash scripts/repo/scrub-unpushed-history.sh --apply    # rewrite, after a typed confirmation
# env: SCRUB_BASE (default origin/main), SCRUB_BRANCH (default main),
#      SCRUB_FLAKE (flake pinning nixpkgs for git-filter-repo; default: this repo)
#
# Safety: dry run by default; refuses a dirty tree; refuses unless the base is
# an ancestor of the branch; saves refs/backup/pre-scrub-<timestamp> before
# rewriting; needs `scrub <branch>` typed; verifies afterwards.
# Uses git-filter-repo from this flake's nixpkgs (nix shell --inputs-from .).
set -euo pipefail

die() {
  echo "scrub: $*" >&2
  exit 1
}

mode=dry
case "${1:-}" in
  "" | --dry-run) ;;
  --apply) mode=apply ;;
  -h | --help)
    sed -n '2,28p' "$0"
    exit 0
    ;;
  *) die "unknown argument '$1' (--dry-run | --apply)" ;;
esac

repo=$(git rev-parse --show-toplevel) || die "not in a git repository"
cd "$repo"
base=${SCRUB_BASE:-origin/main}
branch=${SCRUB_BRANCH:-main}
strings=${SCRUB_STRINGS:-$repo/scripts/repo/scrub-strings.local}

[ -s "$strings" ] || die "no strings file at $strings (see the header of this script)"
git check-ignore -q "$strings" || [ -n "${SCRUB_STRINGS:-}" ] ||
  die "$strings is not gitignored: refusing (it holds the very strings to remove)"
if [ -z "${SCRUB_BASE:-}" ]; then
  url=$(git remote get-url origin 2>/dev/null || true)
  case "$url" in
    *github.com*) ;;
    *) die "origin is '$url', not GitHub. Run this where origin is GitHub (butternut), or set SCRUB_BASE." ;;
  esac
fi
git rev-parse -q --verify "$base^{commit}" >/dev/null || die "no such base '$base' (git fetch origin first?)"
git rev-parse -q --verify "refs/heads/$branch" >/dev/null || die "no branch '$branch'"
git merge-base --is-ancestor "$base" "$branch" ||
  die "$base is not an ancestor of $branch: the range $base..$branch is not 'the unpushed commits'"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "working tree has uncommitted changes: commit them first"

# Literals (left of ==>), without blank/comment lines.
mapfile -t lits < <(sed -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' -e 's/==>.*$//' "$strings")
[ ${#lits[@]} -gt 0 ] || die "$strings has no strings"
for l in "${lits[@]}"; do
  case "$l" in regex:* | glob:*) die "only literal strings are supported (got '$l')" ;; esac
  [ ${#l} -ge 4 ] || die "string '$l' is too short to replace safely"
done

range="$base..$branch"
n=$(git rev-list --count "$range")
echo ">> range $range: $n commit(s) to rewrite"
echo ">> strings: ${#lits[@]} (from $strings; not printed)"

found=0
i=0
for l in "${lits[@]}"; do
  i=$((i + 1))
  hits=$(git log --format='%h %s' -S"$l" "$range" | wc -l)
  msgs=$(git log --format='%h' -F --grep="$l" "$range" | wc -l)
  tip=$({ git grep -c -F -e "$l" "$branch" -- 2>/dev/null || true; } | wc -l)
  public=$(git log --format='%h' -S"$l" "$base" | wc -l)
  echo "   #$i: added/removed in $hits commit(s), in $msgs message(s); in $tip file(s) at the tip"
  [ "$public" = 0 ] || echo "   #$i: WARNING: also in $public commit(s) ALREADY on $base (public): a scrub cannot fix that"
  [ "$hits" = 0 ] && [ "$msgs" = 0 ] && [ "$tip" = 0 ] || found=1
done
[ "$found" = 1 ] || {
  echo ">> none of the strings occur in $range: nothing to do"
  exit 0
}

filter_repo() {
  nix shell --inputs-from "${SCRUB_FLAKE:-$repo}" nixpkgs#git-filter-repo -c \
    git filter-repo --force --refs "$range" \
    --replace-text "$strings" --replace-message "$strings" "$@"
}

if [ "$mode" = dry ]; then
  echo ">> git filter-repo --dry-run (writes .git/filter-repo/fast-export.{original,filtered})"
  filter_repo --dry-run
  echo ">> compare: diff .git/filter-repo/fast-export.original .git/filter-repo/fast-export.filtered | less"
  echo ">> then re-run with --apply"
  exit 0
fi

backup="refs/backup/pre-scrub-$(date +%Y%m%d-%H%M%S)"
echo
echo "This REWRITES the $n commit(s) of $range (new commit IDs from the first"
echo "affected one on). The other machine's clone must then be reset to the"
echo "new $branch. The old $branch is kept at $backup."
read -r -p "Type 'scrub $branch' to continue: " answer
[ "$answer" = "scrub $branch" ] || die "not confirmed; nothing changed"

git update-ref -m "pre-scrub backup" "$backup" "refs/heads/$branch"
echo ">> backup: $backup"
filter_repo

echo ">> verifying"
bad=0
i=0
for l in "${lits[@]}"; do
  i=$((i + 1))
  if git log -p --format='%H%n%B' "$range" | grep -q -F -e "$l"; then
    echo "   #$i: STILL PRESENT in $range" >&2
    bad=1
  fi
done
[ "$bad" = 0 ] || die "verification failed; restore with: git update-ref refs/heads/$branch $backup && git checkout -f $branch"
echo ">> clean. Next (yourself):"
echo "   git log --oneline $base..$branch | head        # look"
echo "   git push origin $branch                         # only $branch: not refs/backup/*, not refs/remotes/*"
echo "   on the other machine: git fetch <this host> && git checkout main && git reset --hard <this host>/main"
echo "   later, to drop the old objects locally: git update-ref -d $backup; git reflog expire --expire=now --all; git gc --prune=now"
