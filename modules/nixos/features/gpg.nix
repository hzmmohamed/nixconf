{...}: {
  flake.nixosModules.gpg = {
    pkgs,
    ...
  }: {
    programs.gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
      enableExtraSocket = true;
    };

    programs.ssh.startAgent = false;

    environment.systemPackages = with pkgs; [
      gnupg
      pinentry-curses
      pinentry-qt
    ];
  };
}
