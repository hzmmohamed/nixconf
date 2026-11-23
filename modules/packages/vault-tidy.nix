# vault-tidy: sort and audit the KeePassXC vault with a local model
# (llama-swap on peacelily by default). Only titles/URLs/usernames/groups
# reach the model; password checks run locally. See the script's docstring.
#   vault-tidy scan    → ~/.local/state/vault-tidy/<run>/review.md
#   vault-tidy apply   → applies the checked boxes to ~/Vault/vault.kdbx
{...}: {
  perSystem = {pkgs, ...}: {
    packages.vault-tidy =
      pkgs.writers.writePython3Bin "vault-tidy" {
        libraries = [pkgs.python3Packages.pykeepass];
        flakeIgnore = ["E501" "W503"];
        makeWrapperArgs = ["--prefix" "PATH" ":" "${pkgs.procps}/bin"];
      }
      (builtins.readFile ./vault-tidy/vault-tidy.py);
  };
}
