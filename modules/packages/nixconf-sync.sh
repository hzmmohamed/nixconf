# nixconf-sync — body of the `nixconf-sync` package (modules/packages/deploy.nix
# prepends: sync_peers, default_user, default_home, default_port). Not a standalone script.
#
# Keeps the config repo in step between the user's machines without GitHub:
#   1. adds a remote per peer if missing: ssh://<user>@<peer>:<port><home>/nixconf
#   2. fetches every reachable peer (refs/remotes/<peer>/*)
#   3. fast-forwards local `main` to <peer>/main when it is strictly behind;
#      refuses (exit 1, no push) when they have diverged
#   4. pushes the current branch to the peer's refs/remotes/<me>/<branch>:
#      a side ref, so the peer's checked-out branch and working tree (where
#      agents may be working) are never touched. The peer picks it up on its
#      own next `just sync` (its fetch of <me> writes the same ref).
#
#   --dry-run   fetch, then only print the fast-forward / push it would do
#
# env: NIXCONF_SYNC_REPO (default: the repo around $PWD, else ~/nixconf),
#      NIXCONF_SYNC_PEERS (default: the registry desktops), NIXCONF_SYNC_ME
#      (default: hostname), NIXCONF_SYNC_BRANCH (the branch kept in step: main)

die() {
  echo "nixconf-sync: $*" >&2
  exit 1
}

dry=0
case "${1:-}" in
  --dry-run | -n) dry=1 ;;
  "") ;;
  -h | --help)
    echo "usage: nixconf-sync [--dry-run]" >&2
    exit 0
    ;;
  *) die "unknown argument '$1' (usage: nixconf-sync [--dry-run])" ;;
esac

repo=${NIXCONF_SYNC_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/nixconf")}
cd "$repo" || die "no repo at $repo"
git rev-parse --git-dir >/dev/null 2>&1 || die "$repo is not a git repository"

me=${NIXCONF_SYNC_ME:-$(cat /proc/sys/kernel/hostname)}
peers=${NIXCONF_SYNC_PEERS:-$sync_peers}
main=${NIXCONF_SYNC_BRANCH:-main}
user=$default_user
port=$default_port

branch=$(git symbolic-ref --short -q HEAD) || die "detached HEAD: check out a branch first"
# Fail fast on an absent peer instead of hanging on a café network.
export GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-ssh -o ConnectTimeout=5 -o BatchMode=yes}

run() {
  if [ "$dry" = 1 ]; then
    echo "   (dry-run) $*"
  else
    "$@"
  fi
}

status=0
synced=0
for peer in $peers; do
  [ "$peer" = "$me" ] && continue
  echo ">> $peer"
  if ! git remote get-url "$peer" >/dev/null 2>&1; then
    url="ssh://$user@$peer:$port$default_home/nixconf"
    echo "   adding remote $peer → $url"
    git remote add "$peer" "$url"
  fi
  if ! git fetch --quiet "$peer"; then
    echo "   $peer unreachable (or no repo there): skipped" >&2
    continue
  fi
  synced=$((synced + 1))

  diverged=0
  ours="refs/heads/$main"
  theirs="refs/remotes/$peer/$main"
  if git rev-parse -q --verify "$theirs" >/dev/null && git rev-parse -q --verify "$ours" >/dev/null; then
    o=$(git rev-parse "$ours")
    t=$(git rev-parse "$theirs")
    if [ "$o" = "$t" ]; then
      echo "   $main = $peer/$main"
    elif git merge-base --is-ancestor "$o" "$t"; then
      n=$(git rev-list --count "$o..$t")
      echo "   $main is $n commit(s) behind $peer/$main: fast-forwarding"
      if [ "$branch" = "$main" ]; then
        # --ff-only refuses rather than merging; with local edits it only
        # proceeds when they don't touch the incoming files.
        run git merge --ff-only --quiet "$theirs" ||
          die "fast-forward of $main failed (uncommitted changes in the files $peer changed? commit or stash them, then re-run)"
      else
        run git update-ref -m "nixconf-sync: fast-forward from $peer" "$ours" "$t" "$o"
      fi
    elif git merge-base --is-ancestor "$t" "$o"; then
      n=$(git rev-list --count "$t..$o")
      echo "   $main is $n commit(s) ahead of $peer/$main"
    else
      a=$(git rev-list --count "$t..$o")
      b=$(git rev-list --count "$o..$t")
      echo "nixconf-sync: $main and $peer/$main have DIVERGED ($a here, $b on $peer)." >&2
      echo "  Nothing pushed to $peer. Reconcile here, then re-run 'just sync':" >&2
      echo "    git log --oneline --graph $main $peer/$main   # look" >&2
      echo "    git rebase $peer/$main                        # replay yours on top, or" >&2
      echo "    git merge $peer/$main                         # merge" >&2
      diverged=1
      status=1
    fi
  fi

  if [ "$diverged" = 1 ] && [ "$branch" = "$main" ]; then
    continue
  fi
  # Forced: refs/remotes/<me>/* on the peer only ever mirror this repo.
  echo "   pushing $branch → $peer:refs/remotes/$me/$branch"
  run git push --quiet "$peer" "+HEAD:refs/remotes/$me/$branch" || {
    echo "   push to $peer failed" >&2
    status=1
  }
done

[ "$synced" -gt 0 ] || die "no peer reachable (peers: $peers)"
exit "$status"
