{self, ...}: {
  # Distributed builds between the user's machines, driven by the hosts
  # registry (modules/hosts-registry.nix: `builderFor`, `builderKey`):
  #
  #   builder (butternut, builderFor = ["hazel"])
  #     nix.sshServe: user `nix-ssh`, sshd `ForceCommand nix-daemon --stdio`
  #     (no shell, no forwarding, no TTY), authorized for the clients'
  #     `builderKey`s only. `trusted`: ssh-ng remote builds of input-addressed
  #     derivations and unsigned input paths need a trusted user; the key can
  #     do nothing but talk to the daemon.
  #   client (hazel)
  #     /root/.ssh/nix-builder_ed25519 generated at activation if missing (the
  #     daemon connects as root); the switch prints its public half until it
  #     is the registry's `builderKey`. Once it is, nix.buildMachines gets the
  #     builder over ssh-ng with `builders-use-substitutes`, through an ssh
  #     alias `<builder>-builder` that carries the port, the key, the registry
  #     host key (HostKeyAlias) and a 3 s connect timeout.
  #
  # Fallback: when the builder is unreachable the build hook declines and the
  # build runs locally (local max-jobs stays > 0); one hook process marks the
  # machine down after the first failure, so an absent butternut costs ~3 s
  # per `nix build`, not per derivation.
  #
  # Imported by `general` (like hosts-registry): a host that is neither a
  # builder nor a client gets nothing.
  #
  # Prior art: .repos/adingbatponder-config/features/nix-builder (attrset of
  # builders → buildMachines, activation message, `localMaxJobs` for a small
  # client, verification steps). Differences: the registry is the source of
  # truth; the server forces `nix-daemon --stdio` (theirs gives the builder
  # user a shell); the non-standard port really reaches ssh (theirs declares a
  # `port` option and drops it); per-host keys generated on the host instead
  # of one shared key in sops (no decryption-vs-daemon timing, revocation =
  # delete one registry line); host key pinned from the registry instead of a
  # manual first `ssh` as root.
  flake.nixosModules.nix-builder = {
    config,
    lib,
    pkgs,
    ...
  }: let
    me = config.networking.hostName;
    inherit (self) hosts;
    has = attr: h: (h.${attr} or null) != null;

    keyPath = "/root/.ssh/nix-builder_ed25519";

    # Builders that list this host.
    myBuilders = lib.filterAttrs (n: h: n != me && lib.elem me (h.builderFor or [])) hosts;
    myKey = hosts.${me}.builderKey or null;
    isClient = myBuilders != {};
    useBuilders = isClient && myKey != null;

    # Clients this host builds for, with their keys (when known).
    clientKeys =
      lib.filter (k: k != null) (map (c: hosts.${c}.builderKey or null)
        (lib.filter (c: c != me) (hosts.${me}.builderFor or [])));
    isBuilder = clientKeys != [];

    alias = n: "${n}-builder";
    cfg = config.preferences.nix-builder;
  in {
    options.preferences.nix-builder.localMaxJobs = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = 2;
      description = ''
        `max-jobs` on a client that has a builder. Local builds only run when
        the builder is unreachable or all its slots are busy; keep this > 0
        or builds hang while the builder is away. `null` keeps Nix's default.
      '';
    };

    config = lib.mkMerge [
      (lib.mkIf isBuilder {
        nix.sshServe = {
          enable = true;
          protocol = "ssh-ng";
          trusted = true;
          keys = map (k: "restrict ${k}") clientKeys;
        };
      })

      (lib.mkIf isClient {
        system.activationScripts.nix-builder-key = ''
          if [ ! -s ${keyPath} ]; then
            mkdir -p -m 700 /root/.ssh
            ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" \
              -C "root@${me} nix-builder" -f ${keyPath}
          fi
          pub=$(${pkgs.coreutils}/bin/cut -d' ' -f1,2 ${keyPath}.pub)
          if [ "$pub" != ${lib.escapeShellArg (toString myKey)} ]; then
            echo "nix-builder: ${me}'s builder key is not the registry's builderKey yet."
            echo "  In modules/hosts-registry.nix, hosts.${me}:"
            echo "    builderKey = \"$pub\";"
            echo "  then deploy ${lib.concatStringsSep ", " (lib.attrNames myBuilders)} and ${me}."
          fi
        '';
      })

      (lib.mkIf useBuilders {
        nix.distributedBuilds = true;
        nix.settings = {
          builders-use-substitutes = true;
          max-jobs = lib.mkIf (cfg.localMaxJobs != null) cfg.localMaxJobs;
        };
        nix.buildMachines =
          lib.mapAttrsToList (n: h: {
            hostName = alias n;
            protocol = "ssh-ng";
            sshUser = "nix-ssh";
            sshKey = keyPath;
            systems = ["x86_64-linux" "i686-linux"];
            maxJobs = h.builderMaxJobs or 4;
            speedFactor = h.builderSpeedFactor or 2;
            supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
          })
          myBuilders;

        # Root's ssh (the daemon) reads /etc/ssh/ssh_config. The alias is a
        # distinct name, so the registry's `Match originalhost <host>` and
        # `Host <host> …` blocks do not apply: HostName <host> resolves to the
        # tailnet IP (/etc/hosts), and Tailscale itself rides the cable when
        # it is up.
        programs.ssh.extraConfig = lib.mkAfter (lib.concatStrings (lib.mapAttrsToList (n: h: ''
            Host ${alias n}
              HostName ${n}
              Port ${toString (h.sshPort or 22)}
              User nix-ssh
              IdentityFile ${keyPath}
              IdentitiesOnly yes
              BatchMode yes
              ConnectTimeout 3
              ConnectionAttempts 1
              ServerAliveInterval 15
              ServerAliveCountMax 4
              HostKeyAlias ${n}
              StrictHostKeyChecking ${
              if has "hostKey" h
              then "yes"
              else "accept-new"
            }
          '')
          myBuilders));
      })
    ];
  };
}
