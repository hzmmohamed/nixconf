# `just deploy hazel [boot|test]` — see modules/nixos/features/remote-deploy.nix
deploy host action="switch":
    DEPLOY_FLAKE={{justfile_directory()}} deploy {{host}} {{action}}
