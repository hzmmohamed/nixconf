{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    # Single packages/modules newer than 26.05 ships (features/immich.nix: Immich
    # 3.x). Not followed by anything; drop when no feature needs it.
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";

    impermanence.url = "github:nix-community/impermanence";
    persist-retro.url = "github:Geometer1729/persist-retro";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-index-database = {
      url = "github:Mic92/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    wrappers.url = "github:Lassulus/wrappers";
    wrapper-modules.url = "github:BirdeeHub/nix-wrapper-modules";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-gaming.url = "github:fufexan/nix-gaming";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    catppuccin.url = "github:catppuccin/nix";

    # Noctalia v5 (native C++ shell). Deliberately NOT following our nixpkgs:
    # upstream builds against nixos-unstable and publishes to noctalia.cachix.org.
    noctalia.url = "github:noctalia-dev/noctalia";

    claude-code.url = "github:sadjow/claude-code-nix";

    # Fresh agent CLIs (t3code, herdr, opencode, ...). Deliberately NOT
    # following our nixpkgs so we hit cache.numtide.com (see features/nix.nix).
    llm-agents.url = "github:numtide/llm-agents.nix";

    # Claude Code skills/plugins, pinned (exposed by features/agent-common.nix).
    anthropic-skills = {
      url = "github:anthropics/skills";
      flake = false;
    };
    superpowers = {
      url = "github:obra/superpowers";
      flake = false;
    };

    reticulum-flake = {
      url = "git+https://codeberg.org/adingbatponder/reticulum_nixos_flake.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    firefox-addons = {
      url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    devenv.url = "github:cachix/devenv";
    treefmt-nix.url = "github:numtide/treefmt-nix";

    # attn, the attention tracker (features/attn.nix). Private repo: fetched
    # over the owner's GitHub SSH key. Deliberately NOT following our
    # nixpkgs: attn's own package keeps the store path attn's CI builds, so a
    # cache it pushes to can serve deploys.
    attn.url = "git+ssh://git@github.com/hzmmohamed/attn";
  };

  outputs = inputs: inputs.flake-parts.lib.mkFlake {inherit inputs;} (inputs.import-tree ./modules);
}
