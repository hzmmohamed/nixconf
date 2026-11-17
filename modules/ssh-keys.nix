{...}: {
  # Public SSH keys of the user's machines, keyed by the host the private key
  # lives on. Public keys are safe to commit. Consumed by the `openssh` feature
  # as the default for `preferences.ssh.authorizedKeys`.
  #
  # TODO: add hazel's key (`cat ~/.ssh/id_ed25519.pub` on hazel) and maple's
  # if it should be able to log in to the other hosts.
  flake.sshKeys = {
    butternut = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB/BJXdMOwG3kwq6Ho3/0VANt7n5vvDJsL9I56WfMqsF";
  };
}
