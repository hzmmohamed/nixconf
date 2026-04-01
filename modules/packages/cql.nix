{...}: {
  perSystem = {pkgs, ...}: {
    packages.cql = pkgs.stdenv.mkDerivation {
      pname = "cql";
      version = "march_31_2026";

      src = pkgs.fetchurl {
        url = "https://github.com/CategoricalData/CQL/releases/download/march_31_2026/cql.jar";
        hash = "sha256:5530188bbfc9a17d1cc6a231d98dc8cd8c84e9b1171513fed6ac710da4729dd0";
      };

      dontUnpack = true;

      nativeBuildInputs = [pkgs.makeWrapper];

      installPhase = ''
        runHook preInstall
        mkdir -p $out/share/java $out/bin
        cp $src $out/share/java/cql.jar
        makeWrapper ${pkgs.jdk}/bin/java $out/bin/cql \
          --add-flags "-jar $out/share/java/cql.jar"
        runHook postInstall
      '';

      meta = {
        description = "CQL - Categorical Query Language IDE";
        homepage = "https://github.com/CategoricalData/CQL";
        platforms = pkgs.lib.platforms.linux;
        mainProgram = "cql";
      };
    };
  };
}
