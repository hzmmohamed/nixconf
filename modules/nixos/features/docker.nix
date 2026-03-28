{...}: {
  flake.nixosModules.docker = {
    config,
    pkgs,
    ...
  }: {
    virtualisation.docker.enable = true;

    users.users.${config.preferences.user.name}.extraGroups = ["docker"];

    environment.systemPackages = with pkgs; [
      docker-compose
      lazydocker
      dive
    ];
  };
}
