{...}: {
  # Public SSH keys of the user's machines, keyed by the host the private key
  # lives on. Public keys are safe to commit. Consumed by the `openssh` feature
  # as the default for `preferences.ssh.authorizedKeys`, by the initrd SSH
  # unlock (headless-boot) and referenced from the hosts registry (`userKey`).
  #
  # Adding hazel (blocks key-only SSH, `deploy` BatchMode, `herdr --remote`):
  #   1. on hazel: `ssh-keygen -t ed25519` (if needed), `cat ~/.ssh/id_ed25519.pub`
  #   2. paste it into the `hazel` slot below and switch BOTH hosts
  #   3. verify `ssh butternut true` from hazel, then the openssh rollout
  #      (preferences.ssh.passwordAuthentication = false) can proceed.
  # maple/peacelily: add theirs only if they should log in to the other hosts.
  flake.sshKeys = {
    butternut = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB/BJXdMOwG3kwq6Ho3/0VANt7n5vvDJsL9I56WfMqsF";
    # TODO(user): hazel = "ssh-ed25519 AAAA… hfahmi@hazel";
  };
}
