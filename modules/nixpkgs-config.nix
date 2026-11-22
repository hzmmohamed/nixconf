{inputs, ...}: {
  perSystem = {system, ...}: {
    _module.args.pkgs = import inputs.nixpkgs {
      inherit system;
      config = {
        allowUnfree = true;
        # Android SDK licences for the phone app toolchain
        # (modules/packages/phone-app.nix); accepted by the user 2026-11-22.
        android_sdk.accept_license = true;
      };
    };
  };
}
