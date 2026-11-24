# fleet-lib — shared by `deploy` and `fleet` (deploy.nix prepends it to both,
# after the registry data): how to reach a host and what it runs. Not a
# standalone script. Uses: port, user, me; plan_only (deploy --plan) if set.

in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# Keepalives: a target that vanishes (spot stop, Wi-Fi drop) fails within
# ~1 min instead of hanging on a dead connection. Call once `port` is known.
set_ssh_opts() {
  ssh_opts=(-p "$port" -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
  export NIX_SSHOPTS="${ssh_opts[*]}"
}

# Can we log in? In --plan mode nothing is probed: everything is assumed
# reachable except the hosts in DEPLOY_PLAN_UNREACHABLE (tests).
reachable() {
  if [ "${plan_only:-0}" = 1 ]; then
    if in_list "${1%.local}" "${DEPLOY_PLAN_UNREACHABLE:-}"; then return 1; fi
    return 0
  fi
  ssh "${ssh_opts[@]}" -o BatchMode=yes "$user@$1" true 2>/dev/null
}

# find_target <host>: where <host> is. This machine: "local", no ssh at all.
# Otherwise `<host>` first (the registry ssh config takes the cable when it
# is up, else the tailnet IP from /etc/hosts), then `<host>.local` (mDNS).
# Prints nothing and fails when neither answers.
find_target() {
  local candidate
  if [ "$1" = "$me" ]; then
    echo local
    return 0
  fi
  for candidate in "$1" "$1.local"; do
    if reachable "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# Run a command on $target (see find_target). Arguments are store paths or
# fixed words, so client-side expansion is intended.
# shellcheck disable=SC2029
remote() {
  if [ "$target" = local ]; then
    "$@"
  else
    ssh "${ssh_opts[@]}" "$user@$target" "$@"
  fi
}

# The commit $target's running system was built from: system.configuration-
# Revision (base/revision.nix), "<rev>-dirty" for an uncommitted tree, empty
# for systems built before it existed.
running_revision() { remote nixos-version --configuration-revision 2>/dev/null || true; }
