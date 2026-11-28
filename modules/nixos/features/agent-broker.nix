# agent-broker: run agent commands as per-project Unix users
# (docs/plans/2026-11-28-t3-separate-user-spike.md §3). Reusable module
# `services.agent-broker`; nixconf wires it from `agent-t3code` later.
#
# Pieces:
#   - a root broker behind /run/agent-broker/sock (socket activation,
#     Accept=yes, mode 0660 root:<socketGroup>): validates a request against
#     /etc/agent-broker/projects.json and runs `systemd-run --pipe --wait
#     --uid=agent-<project> -p <sandbox…>` with the caller's stdio;
#   - `agent-brokered <cmd> …`, the client, and one `<name>-brokered`
#     wrapper per `commands.<name>` (what T3's `binaryPath` points at);
#   - `t3-terminal-shell` (T3CODE_TERMINAL_SHELL): a brokered shell, so a
#     T3 terminal in a thread is a shell as that project's user;
#   - per project: user `agent-<p>`, group `proj-<p>` (caller + agent),
#     slice `agents-<p>.slice`, tmpfiles for the home, the Claude config dir,
#     the clone root and the worktrees subdir (setgid + default ACLs, so the
#     caller's T3 and the agent can both write), a gitconfig with
#     `safe.directory` for the caller-owned repos.
{...}: {
  flake.nixosModules.agent-broker = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.services.agent-broker;
    python = pkgs.python3;

    mkTool = name: script:
      pkgs.runCommand name {
        nativeBuildInputs = [pkgs.makeWrapper];
        meta.mainProgram = name;
      } ''
        makeWrapper ${python}/bin/python3 $out/bin/${name} --add-flags ${script}
      '';
    broker = mkTool "agent-broker" ./agent-broker/broker.py;
    brokered = mkTool "agent-brokered" ./agent-broker/brokered.py;

    # <name>-brokered wrappers + the terminal shell, one package (its store
    # path is what policies/settings reference: cfg.wrapperPackage).
    wrappers = pkgs.runCommand "agent-broker-wrappers" {} (''
        mkdir -p $out/bin
      ''
      + lib.concatStrings (lib.mapAttrsToList (name: command: ''
          cat > $out/bin/${name}-brokered <<EOF
          #!${pkgs.runtimeShell}
          exec ${lib.getExe brokered} ${command} "\$@"
          EOF
          chmod 755 $out/bin/${name}-brokered
        '')
        cfg.commands)
      + lib.optionalString (cfg.terminalShell != null) ''
        cat > $out/bin/t3-terminal-shell <<EOF
        #!${pkgs.runtimeShell}
        exec ${lib.getExe brokered} ${lib.getExe cfg.terminalShell} "\$@"
        EOF
        chmod 755 $out/bin/t3-terminal-shell
      '');

    allCommands =
      lib.attrValues cfg.commands
      ++ lib.optional (cfg.terminalShell != null) (lib.getExe cfg.terminalShell);

    worktreesSubdir = p: "${cfg.worktreesDir}/${baseNameOf p.path}";

    sandboxProperties = p:
      [
        "UMask=0002"
        "NoNewPrivileges=yes"
        "RestrictSUIDSGID=yes"
        "CapabilityBoundingSet="
        "ProtectSystem=strict"
        "ProtectHome=tmpfs"
        "PrivateTmp=yes"
        "ProtectProc=invisible"
        "ProtectKernelTunables=yes"
        "ProtectKernelModules=yes"
        "ProtectKernelLogs=yes"
        "ProtectControlGroups=yes"
        "ProtectClock=yes"
        "RestrictNamespaces=yes"
        "RestrictRealtime=yes"
        "LockPersonality=yes"
        "SystemCallArchitectures=native"
        "RuntimeMaxSec=${p.runtimeMax}"
        "TimeoutStopSec=15"
        "KillMode=control-group"
        "MemoryMax=${p.limits.memoryMax}"
        "TasksMax=${toString p.limits.tasksMax}"
        "IPAddressDeny=any"
        "IPAddressAllow=localhost"
        # The agent's writable world: its home, the clone, its worktrees.
        "BindPaths=${p.home}"
        "BindPaths=${p.path}"
        "BindPaths=${worktreesSubdir p}"
        "ReadWritePaths=${p.home} ${p.path} ${worktreesSubdir p} /nix/var/nix/daemon-socket"
        # T3 hands the agent paths under its 0700 state dir (attachments,
        # screenshots): an empty tmpfs there with just those subtrees bound.
        "TemporaryFileSystem=${cfg.stateDir}:ro"
      ]
      ++ map (d: "BindReadOnlyPaths=${cfg.stateDir}/${d}") cfg.stateDirBinds
      ++ map (b: "BindPaths=${b}") p.extraBinds
      ++ map (b: "ReadWritePaths=${b}") p.extraBinds
      ++ map (a: "IPAddressAllow=${a}") p.network.allow
      ++ p.extraProperties;

    registry = {
      inherit (cfg) envAllow commandPrefix;
      systemdRun = "${pkgs.systemd}/bin/systemd-run";
      systemctl = "${pkgs.systemd}/bin/systemctl";
      projects =
        lib.mapAttrs (_: p: {
          inherit (p) user group home path claudeConfigDir env envAllow;
          worktreesDir = worktreesSubdir p;
          allowedCommands = allCommands ++ p.allowedCommands;
          path_env = lib.makeBinPath (p.packages ++ cfg.packages) + ":/run/current-system/sw/bin";
          properties = sandboxProperties p;
          commandPrefix = [];
        })
        cfg.projects;
    };
    registryFile = pkgs.writeText "agent-broker-projects.json" (builtins.toJSON registry);

    agentGitconfig = p:
      pkgs.writeText "agent-${p.name}-gitconfig" ''
        # Managed by services.agent-broker: the clone and worktrees are owned
        # by ${cfg.callerUser}; git refuses them without this.
        [safe]
        	directory = ${p.path}
        	directory = ${worktreesSubdir p}/*
        [core]
        	sharedRepository = group
        [user]
        	name = ${p.git.name}
        	email = ${p.git.email}
        ${p.git.extraConfig}
      '';

    projectModule = {name, ...}: {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
          default = name;
          readOnly = true;
        };
        path = lib.mkOption {
          type = lib.types.path;
          description = "The orchestrator's clone of the project (owned by callerUser, group-shared).";
        };
        user = lib.mkOption {
          type = lib.types.str;
          default = "agent-${name}";
        };
        group = lib.mkOption {
          type = lib.types.str;
          default = "proj-${name}";
        };
        home = lib.mkOption {
          type = lib.types.path;
          default = "/var/lib/agents/${name}";
        };
        claudeConfigDir = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = "/var/lib/agents/${name}/claude";
          description = ''
            CLAUDE_CONFIG_DIR for this project (the T3 instance's homePath must
            equal it; a run claiming another is refused). null: no Claude here.
          '';
        };
        allowedCommands = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Extra argv[0] paths this project may run (commands.* and the terminal shell are always allowed).";
        };
        packages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [];
          description = "On the agent's PATH, in addition to services.agent-broker.packages and the system profile.";
        };
        env = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          description = "Fixed environment for every run (wins over the caller's).";
        };
        envAllow = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Caller variables forwarded for this project, beyond the base allow-list.";
        };
        network.allow = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          example = ["10.0.0.5/32" "100.64.0.0/10"];
          description = "IPAddressAllow= entries beyond loopback (the egress proxy, named tailnet services).";
        };
        limits = {
          memoryMax = lib.mkOption {
            type = lib.types.str;
            default = "40%";
          };
          cpuWeight = lib.mkOption {
            type = lib.types.int;
            default = 50;
          };
          tasksMax = lib.mkOption {
            type = lib.types.int;
            default = 2048;
          };
        };
        runtimeMax = lib.mkOption {
          type = lib.types.str;
          default = "12h";
          description = "RuntimeMaxSec= backstop for a run whose broker died.";
        };
        extraBinds = lib.mkOption {
          type = lib.types.listOf lib.types.path;
          default = [];
          description = "Extra writable paths (e.g. an AVD directory).";
        };
        extraProperties = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Extra systemd-run --property= values.";
        };
        git = {
          name = lib.mkOption {
            type = lib.types.str;
            default = "agent-${name}";
          };
          email = lib.mkOption {
            type = lib.types.str;
            default = "agent-${name}@localhost";
          };
          extraConfig = lib.mkOption {
            type = lib.types.lines;
            default = "";
          };
        };
      };
    };
  in {
    options.services.agent-broker = {
      enable = lib.mkEnableOption "the per-project agent broker";

      callerUser = lib.mkOption {
        type = lib.types.str;
        default = "t3";
        description = "The orchestrator user: may connect to the socket, owns the clones, member of every project group.";
      };
      socketGroup = lib.mkOption {
        type = lib.types.str;
        default = "t3";
        description = "Group allowed to connect to the broker socket.";
      };
      socketPath = lib.mkOption {
        type = lib.types.path;
        default = "/run/agent-broker/sock";
        readOnly = true;
      };
      stateDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/t3code/.t3/userdata";
        description = "The orchestrator's T3 state dir (0700); only `stateDirBinds` of it are visible to agents.";
      };
      stateDirBinds = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["attachments" "browser-artifacts"];
      };
      worktreesDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/t3code/.t3/worktrees";
        description = "T3's worktrees root; each project's `<basename path>` subdir is pre-created group-shared.";
      };
      commands = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        example = lib.literalExpression ''{ claude = "''${pkgs.claude-code}/bin/claude"; }'';
        description = "`<name>-brokered` wrappers: run <command> through the broker. Allowed for every project.";
      };
      terminalShell = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = pkgs.bashInteractive;
        description = "Shell behind `t3-terminal-shell` (T3CODE_TERMINAL_SHELL); null disables it.";
      };
      commandPrefix = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = lib.literalExpression ''[ "''${lib.getExe agentDevshell}" ]'';
        description = "Prepended to every command inside the unit (e.g. a dev-shell launcher).";
      };
      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [pkgs.coreutils pkgs.git pkgs.bashInteractive];
        description = "On every agent's PATH.";
      };
      envAllow = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Caller variables forwarded to every project, beyond the broker's base allow-list.";
      };
      projects = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule projectModule);
        default = {};
      };
      wrapperPackage = lib.mkOption {
        type = lib.types.package;
        default = wrappers;
        readOnly = true;
        description = "The `<name>-brokered` and `t3-terminal-shell` wrappers (for binaryPath settings).";
      };
    };

    config = lib.mkIf cfg.enable {
      assertions = let
        basenames = map (p: baseNameOf p.path) (lib.attrValues cfg.projects);
      in [
        {
          assertion = lib.length basenames == lib.length (lib.unique basenames);
          message = "services.agent-broker: project paths must have distinct basenames (T3 keys worktree dirs by basename): ${toString basenames}";
        }
        {
          assertion = cfg.projects == {} || config.users.users ? ${cfg.callerUser};
          message = "services.agent-broker.callerUser (${cfg.callerUser}) is not a declared user";
        }
      ];

      environment.systemPackages = [brokered wrappers];
      environment.etc."agent-broker/projects.json".source = registryFile;

      systemd.sockets.agent-broker = {
        description = "agent broker socket";
        wantedBy = ["sockets.target"];
        socketConfig = {
          ListenStream = cfg.socketPath;
          Accept = true;
          SocketMode = "0660";
          SocketUser = "root";
          SocketGroup = cfg.socketGroup;
          DirectoryMode = "0755";
          MaxConnections = 256;
        };
      };
      systemd.services."agent-broker@" = {
        description = "agent broker connection %i";
        # Restart-triggers: the registry is read per connection, nothing to restart.
        serviceConfig = {
          ExecStart = lib.getExe broker;
          StandardInput = "socket";
          StandardOutput = "journal";
          StandardError = "journal";
          Environment = ["AGENT_BROKER_REGISTRY=/etc/agent-broker/projects.json"];
          # systemd-run talks to the manager; the unit itself runs as the target user.
          KillMode = "process";
          TimeoutStopSec = 60;
        };
        path = [pkgs.systemd];
      };

      users.users = lib.mapAttrs' (_: p:
        lib.nameValuePair p.user {
          isSystemUser = true;
          inherit (p) group home;
          createHome = true;
          homeMode = "0750";
          shell = pkgs.bashInteractive;
          description = "agent user for project ${p.name}";
        })
      cfg.projects;
      users.groups = lib.mapAttrs' (_: p:
        lib.nameValuePair p.group {
          members = [cfg.callerUser p.user];
        })
      cfg.projects;

      systemd.slices = lib.mapAttrs' (_: p:
        lib.nameValuePair "agents-${p.name}" {
          description = "agent runs for project ${p.name}";
          sliceConfig = {
            MemoryMax = p.limits.memoryMax;
            MemoryHigh = p.limits.memoryMax;
            CPUWeight = p.limits.cpuWeight;
            TasksMax = p.limits.tasksMax;
            ManagedOOMMemoryPressure = "kill";
            ManagedOOMMemoryPressureLimit = "50%";
          };
        })
      cfg.projects;

      # Group-shared trees: setgid so new entries carry the project group, a
      # default ACL so the group gets rwx regardless of the creator's umask
      # (T3 runs with UMask=0002 too, see services.t3code). `a+` is
      # non-recursive: existing content is the clone's business.
      systemd.tmpfiles.rules = lib.concatMap (p: let
        shared = dir: owner: [
          "d ${dir} 2770 ${owner} ${p.group} -"
          "a+ ${dir} - - - - default:group:${p.group}:rwx,group:${p.group}:rwx"
        ];
      in
        shared p.home p.user
        ++ shared "${p.home}/tmp" p.user
        ++ lib.optionals (p.claudeConfigDir != null) (shared p.claudeConfigDir p.user)
        ++ ["d ${dirOf p.path} 0755 ${cfg.callerUser} ${cfg.callerUser} -"]
        ++ shared p.path cfg.callerUser
        ++ ["d ${cfg.worktreesDir} 0755 ${cfg.callerUser} ${cfg.callerUser} -"]
        ++ shared (worktreesSubdir p) cfg.callerUser
        ++ ["L+ ${p.home}/.gitconfig - - - - ${agentGitconfig p}"]) (lib.attrValues cfg.projects);
    };
  };

  perSystem = {pkgs, ...}: {
    checks.agent-broker = pkgs.runCommand "agent-broker-check" {nativeBuildInputs = [pkgs.python3];} ''
      cp -r ${./agent-broker} agent-broker
      export HOME=$TMPDIR
      python3 -m unittest discover -s agent-broker/tests -v
      touch $out
    '';
  };
}
