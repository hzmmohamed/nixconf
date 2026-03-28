{...}: {
  flake.nixosModules.rbw = {pkgs, ...}: {
    environment.systemPackages = with pkgs; [
      rbw
      pinentry-qt
    ];
  };
}
