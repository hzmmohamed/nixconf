# The commit each system was built from (`nixos-version
# --configuration-revision`; "<rev>-dirty" for an uncommitted tree). `deploy`
# reads it on the target to refuse a checkout older than what runs there.
{self, ...}: {
  flake.nixosModules.base = {
    system.configurationRevision = self.rev or self.dirtyRev or null;
  };
}
