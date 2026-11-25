package nixconf.phone.ime

import nixconf.phone.drafts.TIER_PERSONAL
import nixconf.phone.drafts.TIER_WORK

// A draft's privacy tier (training lab, as dictate-stream's tier_for): an
// explicit flip wins; else work iff the target app's package is on the
// profile's work list (exact match); anything else, including no app, is
// personal.
fun tierFor(pkg: String?, workApps: List<String>, override: String?): String = when {
    override == TIER_WORK || override == TIER_PERSONAL -> override
    !pkg.isNullOrEmpty() && pkg in workApps -> TIER_WORK
    else -> TIER_PERSONAL
}

/** The tier a tap on the chip gives. */
fun flipped(tier: String): String = if (tier == TIER_WORK) TIER_PERSONAL else TIER_WORK
