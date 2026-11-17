{self, ...}: {
  flake.nixosModules.general = {
    pkgs,
    config,
    lib,
    ...
  }: {
    imports = [
      self.nixosModules.extra_hjem
      self.nixosModules.fish
      self.nixosModules.gtk
      self.nixosModules.nix
    ];

    users.users.${config.preferences.user.name} = {
      isNormalUser = true;
      description = "${config.preferences.user.name}'s account";
      extraGroups = ["wheel" "networkmanager"];
      shell = self.packages.${pkgs.stdenv.hostPlatform.system}.environment;

      # SECURITY TODO: this hash is committed to a PUBLIC repo. Once
      # `preferences.user.passwordFromSops = true` is switched and verified on
      # every host, DELETE it. It stays in git history, so the sops-managed
      # password must be a NEW one.
      hashedPassword =
        lib.mkIf (!config.preferences.user.passwordFromSops) ''
          $6$cH3.3pfi3t/.1q.y$xsVbp6gVp2OtOTDsJaPZga1wvHCBOrMwOEu.Cn/gGQRII8sqs5pOIprNY4Lobkax5PmodprHGhDtPVvIk6IIi1'';
    };

    persistance.data.directories = [
      "nixconf"

      "Videos"
      "Documents"
      "Projects"

      ".ssh"
    ];

    # todo: remove
    persistance.cache.directories = [
      ".local/share/zoxide"
      ".local/share/direnv"
      ".local/share/nvim"
      ".local/share/fish"
      ".config/nvim"
    ];
  };
}
