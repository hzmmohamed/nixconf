package nixconf.phone.segment

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SegmenterTest {
    // One probability per frame, in order; 0 after the script ends.
    private class ScriptedVad(private val ps: List<Float>) : SpeechProbability {
        private var i = 0
        override fun probability(frame: FloatArray): Float = ps.getOrElse(i++) { 0f }
    }

    private fun ps(vararg runs: Pair<Int, Float>): List<Float> = runs.flatMap { (n, p) -> List(n) { p } }

    // Frame k holds k / 10000 in every sample (to find where a segment's samples came from),
    // or [amplitude] of k when given.
    private fun run(
        script: List<Float>,
        pauseMs: Int = 550,
        maxSegmentSec: Int = 25,
        frames: Int = script.size,
        amplitude: (Int) -> Float = { it / 10000f },
        flush: Boolean = false,
    ): List<Pair<Int, Segment>> {
        val seg = Segmenter(ScriptedVad(script), pauseMs, maxSegmentSec)
        val out = mutableListOf<Pair<Int, Segment>>()
        for (k in 0 until frames) seg.feed(FloatArray(FRAME) { amplitude(k) }).forEach { out += k to it }
        if (flush) seg.flush().forEach { out += frames to it }
        return out
    }

    private fun frameOf(sample: Float) = Math.round(sample * 10000)

    @Test
    fun pause_closes_segment_with_pads() {
        // Speech in frames 20..39; 550 ms = 8800 samples of pause: the 18th silent frame closes it.
        val out = run(ps(20 to 0f, 20 to 0.9f, 30 to 0f))
        val (k, s) = out.single()
        assertEquals(57, k)
        assertEquals(20 * 512L - 3200, s.start) // 200 ms before the first voiced frame
        assertEquals(40 * 512L + 2400, s.end) // 150 ms after the last
        assertEquals((s.end - s.start).toInt(), s.samples.size)
        assertEquals(13, frameOf(s.samples.first())) // sample 7040 is in frame 13
        assertEquals(44, frameOf(s.samples.last()))
    }

    @Test
    fun hysteresis_opens_at_threshold_and_stays_voiced_above_threshold_minus_015() {
        // 0.4 never opens a segment …
        assertTrue(run(ps(60 to 0.4f)).isEmpty())
        // … but keeps an open one voiced: no close inside the 0.4 run.
        val out = run(ps(5 to 0f, 10 to 0.9f, 40 to 0.4f, 30 to 0f))
        val (k, s) = out.single()
        assertEquals(55 + 17, k)
        assertEquals(55 * 512L + 2400, s.end)
    }

    @Test
    fun segment_start_clamped_to_recording_start_and_last_cut() {
        // Speech from frame 2: 200 ms before it is before the recording.
        assertEquals(0L, run(ps(2 to 0f, 20 to 0.9f, 30 to 0f)).single().second.start)

        // 250 ms pause: B's pad would reach back into A, so B starts where A ended.
        val out = run(ps(20 to 0f, 20 to 0.9f, 8 to 0f, 20 to 0.9f, 30 to 0f), pauseMs = 250)
        assertEquals(2, out.size)
        val (a, b) = out.map { it.second }
        assertEquals(40 * 512L + 2400, a.end)
        assertEquals(a.end, b.start)
        assertEquals(68 * 512L + 2400, b.end)
    }

    @Test
    fun short_burst_dropped_but_still_a_cut() {
        // 7 voiced frames (224 ms) < 250 ms: dropped; 8 (256 ms) kept.
        assertTrue(run(ps(20 to 0f, 7 to 0.9f, 30 to 0f)).isEmpty())
        assertEquals(1, run(ps(20 to 0f, 8 to 0.9f, 30 to 0f)).size)

        // The dropped burst still moves the floor: the next segment starts after it.
        val out = run(ps(20 to 0f, 7 to 0.9f, 8 to 0f, 20 to 0.9f, 30 to 0f), pauseMs = 250)
        assertEquals(27 * 512L + 2400, out.single().second.start)
    }

    @Test
    fun long_speech_split_at_quietest_point_of_last_40_percent() {
        // 5 s max = 80000 samples; frames 120..122 are the quiet ones (the
        // window searched starts at 3 s, frame 94); frame 10 is quieter but too early.
        val loud = { k: Int -> if (k in 120..122 || k == 10) 0.001f else 0.5f }
        val out = run(ps(300 to 0.9f, 30 to 0f), maxSegmentSec = 5, amplitude = loud)
        assertEquals(156, out[0].first) // the frame that reached 80000 samples
        val first = out[0].second
        assertEquals(0L, first.start)
        assertEquals(121 * 512L + 256, first.end) // middle of the quietest 3 frames
        // The rest goes on from the cut, without a gap.
        assertEquals(first.end, out[1].second.start)
        assertTrue(out[1].second.end - out[1].second.start <= 80000)
        assertEquals(out[1].second.end, out[2].second.start)
        assertEquals(3, out.size)
    }

    @Test
    fun flush_after_a_split_closes_the_rest() {
        // Energy rises frame by frame: the quietest window is the first one searched (frames 94..96).
        val out = run(ps(200 to 0.9f), maxSegmentSec = 5, flush = true)
        assertEquals(2, out.size)
        assertEquals(95 * 512L + 256, out[0].second.end)
        assertEquals(out[0].second.end, out[1].second.start)
        assertEquals(200 * 512L, out[1].second.end) // still speaking at the end
    }

    @Test
    fun flush_closes_the_open_segment_and_clamps_the_pad() {
        // Voiced until 2 frames before the end: end = last voiced + 150 ms, but not past what was fed.
        val out = run(ps(20 to 0f, 20 to 0.9f, 2 to 0f), flush = true)
        val s = out.single().second
        assertEquals(42 * 512L, s.end)
        assertEquals(42, out.single().first)

        // Nothing open: nothing to flush; a short open burst is dropped.
        assertTrue(run(ps(20 to 0f), flush = true).isEmpty())
        assertTrue(run(ps(20 to 0f, 5 to 0.9f), flush = true).isEmpty())
    }

    @Test
    fun speaking_follows_the_segment() {
        val seg = Segmenter(ScriptedVad(ps(2 to 0f, 10 to 0.9f, 20 to 0f)), 550, 25)
        repeat(2) { seg.feed(FloatArray(FRAME)) }
        assertFalse(seg.speaking)
        repeat(10) { seg.feed(FloatArray(FRAME)) }
        assertTrue(seg.speaking)
        repeat(20) { seg.feed(FloatArray(FRAME)) }
        assertFalse(seg.speaking)
    }
}
