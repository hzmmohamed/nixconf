{...}: {
  # `deploy <host> [switch|boot|test|dry-activate]` — build a host's system
  # from the local flake checkout, copy it over SSH and activate it there.
  #
  # Target: `<host>.local` (mDNS, works over a bare ethernet cable) and then
  # `<host>` (Tailscale MagicDNS / /etc/hosts). Activation uses doas on the
  # target (no sudo, so `nixos-rebuild --target-host --sudo` is out). The
  # deploying user is in wheel → a trusted Nix user on the target, so
  # unsigned local builds are accepted by `nix copy`.
  #
  # Env: DEPLOY_FLAKE (default ~/nixconf), DEPLOY_SSH_PORT (default 7654),
  #      DEPLOY_USER (default: the primary user), DEPLOY_TARGET (skip lookup).
  flake.nixosModules.remote-deploy = {
    config,
    pkgs,
    ...
  }: let
    deploy = pkgs.writeShellApplication {
      name = "deploy";
      runtimeInputs = with pkgs; [openssh coreutils nix];
      text = ''
        usage() {
          echo "usage: deploy <host> [switch|boot|test|dry-activate]" >&2
          exit 2
        }
        die() {
          echo "deploy: $*" >&2
          exit 1
        }

        [ $# -ge 1 ] && [ $# -le 2 ] || usage
        host=$1
        action=''${2:-switch}
        case "$action" in
          switch | boot | test | dry-activate) ;;
          *) usage ;;
        esac

        flake=''${DEPLOY_FLAKE:-$HOME/nixconf}
        port=''${DEPLOY_SSH_PORT:-7654}
        user=''${DEPLOY_USER:-${config.preferences.user.name}}
        [ -f "$flake/flake.nix" ] || die "no flake at $flake (set DEPLOY_FLAKE)"

        ssh_opts=(-p "$port" -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
        export NIX_SSHOPTS="''${ssh_opts[*]}"

        # 1. Find a reachable address before spending time on the build.
        target=''${DEPLOY_TARGET:-}
        if [ -z "$target" ]; then
          for candidate in "$host.local" "$host"; do
            if ssh "''${ssh_opts[@]}" -o BatchMode=yes "$user@$candidate" true 2>/dev/null; then
              target=$candidate
              break
            fi
          done
        fi
        if [ -z "$target" ]; then
          echo "deploy: cannot log in to $host.local or $host on port $port as $user." >&2
          echo "  - cable: is the link up? (nmcli device; ping $host.local)" >&2
          echo "  - key: if 'ssh -p $port $user@$host.local' asks for a password, this" >&2
          echo "    machine's key is not in modules/ssh-keys.nix on $host yet — switch" >&2
          echo "    $host locally once (see docs/plans/2026-11-17-user-actions.md)." >&2
          exit 1
        fi
        echo ">> deploying $host via $user@$target ($action)"

        # 2. Build locally.
        system=$(nix build --no-link --print-out-paths \
          "$flake#nixosConfigurations.$host.config.system.build.toplevel") ||
          die "build failed"
        echo ">> built $system"

        # 3. Copy the closure (substitutes on the target are not used: the
        #    cable is usually faster than the target's internet).
        nix copy --to "ssh-ng://$user@$target" "$system" || die "nix copy failed"

        # Arguments are store paths/fixed words, so client-side expansion is intended.
        # shellcheck disable=SC2029
        remote() { ssh "''${ssh_opts[@]}" "$user@$target" "$@"; }

        # 4. Show what changes, on the target, against its running system.
        remote nix store diff-closures /run/current-system "$system" || true

        # 5. Activate.
        if [ "$action" = switch ] || [ "$action" = boot ]; then
          remote doas nix-env -p /nix/var/nix/profiles/system --set "$system" ||
            die "setting the system profile failed (passwordless doas on $host?)"
        fi
        remote doas "$system/bin/switch-to-configuration" "$action" ||
          die "switch-to-configuration $action failed on $host"
        echo ">> $host: $action done"
      '';
    };
  in {
    environment.systemPackages = [deploy];
  };
}
