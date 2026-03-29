{inputs, ...}: {
  perSystem = {
    pkgs,
    lib,
    ...
  }: let
    python3Packages = pkgs.python313Packages;

    # Use rns and lxmf from the reticulum flake overlay
    reticulumPkgs = inputs.reticulum-flake.packages.${pkgs.system};

    meshchatxSrc = pkgs.fetchgit {
      url = "https://git.quad4.io/RNS-Things/MeshChatX.git";
      rev = "3da8eab9e4bf6b7d39d71c47ac72c884d5076d13";
      hash = "sha256-zoRPwAUYCwpauVZG43qxBv0XQQSdrtaBrKEk9/NL7qQ=";
    };

    # pycodec2 - Cython bindings for the codec2 speech codec
    pycodec2 = python3Packages.buildPythonPackage {
      pname = "pycodec2";
      version = "4.1.0";
      pyproject = true;

      src = pkgs.fetchPypi {
        pname = "pycodec2";
        version = "4.1.0";
        hash = "sha256-RqSR9MjiMoy2M7QO9tzL0uoI2lH2t255XE16Q5+NNVs=";
      };

      # Relax numpy build-time pin (2.1.* -> >=2.1) in pyproject.toml
      postPatch = ''
        sed -i 's/"numpy==2\.1\.\*"/"numpy>=2.1"/' pyproject.toml
      '';

      build-system = [
        python3Packages.setuptools
        python3Packages.cython
        python3Packages.numpy
      ];

      buildInputs = [pkgs.codec2];

      dependencies = [python3Packages.numpy];

      pythonImportsCheck = ["pycodec2"];
      doCheck = false;
    };

    # LXMFy - pure Python bot framework for Reticulum
    lxmfy = python3Packages.buildPythonPackage {
      pname = "lxmfy";
      version = "1.6.1";
      pyproject = true;

      src = pkgs.fetchgit {
        url = "https://git.quad4.io/LXMFy/LXMFy.git";
        rev = "ccfb41ad519bf9ea93c956f5913979f7947840ce";
        hash = "sha256-WAuGIk5eLE6uwW03CflZceQYAqHgO+vcHWgVtpyfV88=";
      };

      build-system = [python3Packages.poetry-core];

      dependencies = [
        reticulumPkgs.rns
        reticulumPkgs.lxmf
      ];

      # Relax version constraints (reticulum flake has rns 1.1.3, lxmf 0.9.2)
      pythonRelaxDeps = ["lxmf" "rns"];

      pythonImportsCheck = ["lxmfy"];
      doCheck = false;
    };

    # LXST - Lightweight Extensible Signal Transport
    lxst = python3Packages.buildPythonPackage {
      pname = "lxst";
      version = "0.4.5";
      pyproject = true;

      src = pkgs.fetchFromGitHub {
        owner = "markqvist";
        repo = "LXST";
        rev = "1194c9011fe6402edc7aebe7ffe9650ea3b1afee";
        hash = "sha256-/NXMGR5v81m1WDtyiKkizXJ/dbRr6m8zp/viVosyahQ=";
      };

      build-system = [
        python3Packages.setuptools
        python3Packages.wheel
      ];

      dependencies =
        [
          reticulumPkgs.rns
          reticulumPkgs.lxmf
          python3Packages.numpy
          python3Packages.cffi
          pycodec2
        ]
        ++ lib.optionals (lib.versionAtLeast python3Packages.python.version "3.13") [
          python3Packages.audioop-lts
        ];

      # Relax lxmf version constraint (reticulum flake has 0.9.2, LXST wants >=0.9.3)
      pythonRelaxDeps = ["lxmf"];

      pythonImportsCheck = ["LXST"];
      doCheck = false;
    };

    # Build the MeshChatX frontend (Vue/Vite)
    frontend = pkgs.stdenv.mkDerivation (finalAttrs: {
      pname = "meshchatx-frontend";
      version = "4.3.1";
      src = meshchatxSrc;

      pnpmDeps = pkgs.fetchPnpmDeps {
        inherit (finalAttrs) pname src version;
        fetcherVersion = 3;
        hash = "sha256-qx0aPB3OW2R+/oupqhGu+JjPEQymeLLUyeCPOcVIws4=";
      };

      nativeBuildInputs = [
        pkgs.nodejs_22
        pkgs.pnpm_10
        pkgs.pnpmConfigHook
      ];

      env = {
        ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
        PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
        PUPPETEER_SKIP_DOWNLOAD = "true";
        VITE_BUILD_TARGET = "web";
      };

      buildPhase = ''
        runHook preBuild
        pnpm run build-frontend
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out
        cp -r meshchatx/public/* $out/
        runHook postInstall
      '';
    });
  in {
    packages.meshchatx-appimage = pkgs.appimageTools.wrapType2 {
      pname = "meshchatx";
      version = "4.3.1";

      src = pkgs.fetchurl {
        url = "https://git.quad4.io/RNS-Things/MeshChatX/releases/download/v4.3.1/ReticulumMeshChatX-v4.3.1-linux-x86_64.AppImage";
        hash = "sha256-3ZyE79vjr/3FHA0ft2rKY9rHZimgKG973XzV1YkS188=";
      };

      extraPkgs = pkgs: [pkgs.libsecret];

      meta = {
        description = "MeshChatX desktop app (AppImage)";
        homepage = "https://git.quad4.io/RNS-Things/MeshChatX";
        license = lib.licenses.mit;
        mainProgram = "meshchatx";
        platforms = ["x86_64-linux"];
      };
    };

    packages.meshchatx-desktop-entry = pkgs.makeDesktopItem {
      name = "meshchatx";
      desktopName = "MeshChatX";
      comment = "Reticulum mesh network chat";
      exec = "meshchatx --headless";
      terminal = false;
      categories = ["Network" "Chat"];
      mimeTypes = [];
    };

    packages.meshchatx = python3Packages.buildPythonApplication {
      pname = "meshchatx";
      version = "4.3.1";
      pyproject = true;

      src = meshchatxSrc;

      build-system = [
        python3Packages.setuptools
        python3Packages.wheel
      ];

      dependencies = [
        python3Packages.aiohttp
        python3Packages.psutil
        python3Packages.websockets
        python3Packages.bcrypt
        python3Packages.aiohttp-session
        python3Packages.cryptography
        python3Packages.requests
        python3Packages.ply
        python3Packages.pycparser
        python3Packages.jaraco-context
        reticulumPkgs.rns
        reticulumPkgs.lxmf
        lxmfy
        lxst
      ];

      # Relax version constraints from reticulum flake
      pythonRelaxDeps = ["lxmf" "rns" "lxst" "lxmfy" "pycparser"];

      # Install pre-built frontend assets and rename binary
      postInstall = ''
        site="$out/lib/python${python3Packages.python.pythonVersion}/site-packages/meshchatx"
        mkdir -p "$site/public"
        cp -r ${frontend}/* "$site/public/"
        mv "$out/bin/meshchat" "$out/bin/meshchatx"
      '';

      pythonImportsCheck = ["meshchatx"];
      doCheck = false;

      meta = {
        description = "MeshChatX - A Reticulum MeshChat fork with extended features";
        homepage = "https://git.quad4.io/RNS-Things/MeshChatX";
        license = lib.licenses.mit;
        mainProgram = "meshchatx";
        platforms = lib.platforms.linux;
      };
    };
  };
}
