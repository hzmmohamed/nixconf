{...}: {
  flake.nixosModules.aws = {
    pkgs,
    ...
  }: {
    environment.systemPackages = with pkgs; [
      awscli2
      aws-vault
    ];

    environment.variables.AWS_VAULT_BACKEND = "file";
  };
}
