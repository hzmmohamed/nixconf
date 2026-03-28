{self, ...}: {
  flake.nixosModules.general = {
    pkgs,
    config,
    ...
  }: {
    imports = [
      self.nixosModules.extra_hjem
      self.nixosModules.gtk
      self.nixosModules.nix
    ];

    users.users.${config.preferences.user.name} = {
      isNormalUser = true;
      description = "${config.preferences.user.name}'s account";
      extraGroups = ["wheel" "networkmanager"];
      shell = self.packages.${pkgs.system}.environment;

      hashedPassword = ''
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
