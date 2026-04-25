{...}: {
  perSystem = {
    pkgs,
    lib,
    ...
  }: {
    packages.ffflow = pkgs.rustPlatform.buildRustPackage rec {
      pname = "ffflow";
      version = "0.1.1";

      src = pkgs.fetchFromGitHub {
        owner = "yugaaank";
        repo = "ffflow";
        rev = "f72e302fbf5edd52f50b6859d0328bce383bf6ee";
        hash = "sha256-Wjjl9hpsU2lF69KB7JfS90zPyE5+ybHYFCMEYk4Wcv0=";
      };

      cargoHash = "sha256-fsxYSya7QtWtnbGPj2BYEiRS2m+qhxveUC1bABWMdbE=";

      nativeBuildInputs = [pkgs.pkg-config];

      meta = {
        description = "FFmpeg workflow automation CLI/TUI with real-time progress tracking";
        homepage = "https://github.com/yugaaank/ffflow";
        license = lib.licenses.mit;
        platforms = lib.platforms.linux;
        mainProgram = "ffflow";
      };
    };
  };
}
