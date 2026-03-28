{inputs, ...}: {
  perSystem = {pkgs, ...}: {
    packages.fish = inputs.wrappers.lib.wrapPackage {
      inherit pkgs;
      package = pkgs.fish;
    };
  };
}
