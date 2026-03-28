{...}: {
  flake.nixosModules.adb = {
    pkgs,
    ...
  }: {
    environment.systemPackages = [pkgs.android-tools];
  };
}
