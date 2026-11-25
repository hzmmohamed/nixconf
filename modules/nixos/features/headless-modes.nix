{...}: {
  perSystem = {pkgs, ...}: {
    checks.headless-modes =
      pkgs.runCommand "headless-modes-check" {
        nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnused];
      } ''
        bash ${./headless-modes-test.sh} ${./headless-modes.sh}
        touch $out
      '';
  };
}
