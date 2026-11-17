# The tailnet policy file. docs/tailscale-policy.hujson stays the single
# source (comments and all; the API stores HuJSON verbatim).
#
# The provider validates the file against the API at plan time (syntax and
# the policy's `tests`), so `plan.sh` replaces `tailscale.sh acl`.
#
# Import, never overwrite blindly: the import block adopts the live policy,
# so the first plan shows the live → repo diff as an in-place update.
# overwrite_existing_content stays false: if the import were ever skipped,
# create fails with 412 ("import the ACL first") instead of clobbering a
# console-edited policy. To force a create over a non-default policy (e.g.
# after `tofu state rm tailscale_acl.this`), back up the live policy and set
# it to true for one apply; the import below is the normal path.
import {
  to = tailscale_acl.this
  id = "acl" # the ID is ignored by the provider
}

resource "tailscale_acl" "this" {
  acl = file("${path.module}/../../docs/tailscale-policy.hujson")

  # Destroying the resource only drops it from state (the default).
  reset_acl_on_destroy = false
}
