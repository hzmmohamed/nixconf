package nixconf.phone.segment

// Pause-based segmentation, ported from the desktop (dictate-stream.py,
// Segmenter): one recording is cut at natural pauses so each piece is
// transcribed while recording goes on. All positions are sample indexes of
// the recording (16 kHz).

const val RATE = 16000

/** Silero's window: 512 samples, 32 ms. */
const val FRAME = 512

/** Speech probability (0..1) of one [FRAME] of samples in -1..1; called with the frames in order. */
interface SpeechProbability : AutoCloseable {
    fun probability(frame: FloatArray): Float

    override fun close() {}
}

/** A closed segment: samples [start, end) of the recording. */
class Segment(val start: Long, val end: Long, val samples: FloatArray)

/**
 * Speech segments from a stream of frames. Opens at the first frame at or
 * above [threshold] (minus 200 ms, never before the last cut), closes after
 * [pauseMs] of frames below `threshold - 0.15` (plus 150 ms), and splits a
 * segment longer than [maxSegmentSec] at the quietest ~100 ms of its last
 * 40 %. Segments with less than 250 ms of voiced audio are dropped.
 */
class Segmenter(
    private val vad: SpeechProbability,
    pauseMs: Int,
    maxSegmentSec: Int,
    threshold: Double = 0.5,
) {
    private val on = threshold
    private val off = threshold - 0.15
    private val pause = pauseMs.toLong() * RATE / 1000
    private val maxLen = maxSegmentSec.toLong() * RATE

    private class Energy(val offset: Long, val value: Double)

    private val frames = ArrayDeque<FloatArray>() // recent frames; the first starts at bufOff
    private var bufOff = 0L
    private var pos = 0L // samples consumed
    private var energy = ArrayList<Energy>() // per frame since segStart
    private var inSpeech = false
    private var segStart = 0L
    private var voiced = 0L
    private var lastVoicedEnd = 0L
    private var floor = 0L // no segment may start before this (the last cut)

    /** Inside a segment (speech heard, its pause not yet over). */
    val speaking: Boolean get() = inSpeech

    /** Takes one [FRAME] (kept: do not reuse the array); returns the segments it closed. */
    fun feed(frame: FloatArray): List<Segment> {
        val out = mutableListOf<Segment>()
        val p = vad.probability(frame).toDouble()
        val start = pos
        frames.addLast(frame)
        pos += frame.size
        var e = 0.0
        for (x in frame) e += x.toDouble() * x
        if (!inSpeech) {
            if (p >= on) {
                inSpeech = true
                segStart = maxOf(start - PAD_PRE, floor, bufOff)
                voiced = frame.size.toLong()
                lastVoicedEnd = pos
                energy = arrayListOf(Energy(start, e))
            }
        } else {
            energy.add(Energy(start, e))
            if (p >= off) {
                voiced += frame.size
                lastVoicedEnd = pos
            }
            if (pos - lastVoicedEnd >= pause) {
                emit(segStart, minOf(lastVoicedEnd + PAD_POST, pos))?.let(out::add)
                inSpeech = false
            } else if (pos - segStart >= maxLen) {
                val cut = quietestCut()
                emit(segStart, cut)?.let(out::add)
                segStart = cut
                energy = energy.filterTo(ArrayList()) { it.offset >= cut }
                voiced = FRAME.toLong() * energy.size
            }
        }
        trim()
        return out
    }

    /** Closes the open segment (at stop). */
    fun flush(): List<Segment> {
        if (!inSpeech) return emptyList()
        inSpeech = false
        return listOfNotNull(emit(segStart, minOf(lastVoicedEnd + PAD_POST, pos)))
    }

    private fun emit(start: Long, end: Long): Segment? {
        floor = end
        if (voiced < MIN_SPEECH) return null
        return Segment(start, end, take(start, end))
    }

    private fun take(start: Long, end: Long): FloatArray {
        val from = maxOf(start, bufOff)
        val out = FloatArray(maxOf(0L, end - from).toInt())
        var off = bufOff
        for (f in frames) {
            val a = maxOf(from, off)
            val b = minOf(end, off + f.size)
            if (a < b) System.arraycopy(f, (a - off).toInt(), out, (a - from).toInt(), (b - a).toInt())
            off += f.size
            if (off >= end) break
        }
        return out
    }

    private fun trim() {
        val keepFrom = if (inSpeech) segStart else pos - PAD_PRE
        while (frames.isNotEmpty() && bufOff + frames.first().size <= keepFrom) {
            bufOff += frames.removeFirst().size
        }
    }

    // The middle of the quietest 3 frames in the segment's last 40 %.
    private fun quietestCut(): Long {
        val lo = segStart + (maxLen * 0.6).toLong()
        val cand = energy.filter { it.offset >= lo }
        if (cand.size < 3) return pos
        var best = 0
        var bestSum = Double.MAX_VALUE
        for (i in 0..cand.size - 3) {
            val sum = cand[i].value + cand[i + 1].value + cand[i + 2].value
            if (sum < bestSum) {
                best = i
                bestSum = sum
            }
        }
        return cand[best + 1].offset + FRAME / 2
    }

    private companion object {
        const val PAD_PRE = RATE / 5L
        const val PAD_POST = RATE * 3 / 20L
        const val MIN_SPEECH = RATE / 4L
    }
}
