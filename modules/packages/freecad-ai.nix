{...}: {
  perSystem = {
    pkgs,
    lib,
    ...
  }: {
    packages.freecad-ai = pkgs.stdenv.mkDerivation {
      pname = "freecad-ai";
      version = "unstable-2025-04-09";

      src = pkgs.fetchFromGitHub {
        owner = "ghbalf";
        repo = "freecad-ai";
        rev = "182de44798b20abc1cfcc7bde8bdac6faff13ea4";
        hash = "sha256-iL13YXUT9cMtySdaNaATsWY1OWjyi9LzpaOAw3MlZUI=";
      };

      dontBuild = true;

      installPhase = ''
        mkdir -p $out/share/FreeCAD/Mod
        cp -r . $out/share/FreeCAD/Mod/freecad-ai
      '';

      meta = {
        description = "AI-powered assistant workbench for FreeCAD";
        homepage = "https://github.com/ghbalf/freecad-ai";
        license = lib.licenses.mit;
        platforms = lib.platforms.linux;
      };
    };
  };
}
