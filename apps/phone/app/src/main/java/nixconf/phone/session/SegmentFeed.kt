package nixconf.phone.session

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.launch
import nixconf.phone.segment.Framer
import nixconf.phone.segment.Segment
import nixconf.phone.segment.Segmenter
import nixconf.phone.segment.SpeechProbability

/**
 * The recording's live side: [tap] (on the audio thread) only copies the
 * samples into a queue; VAD and segmenter run on [io], and the segments they
 * close come out in order on [segments], which closes after [end] (with the
 * open segment flushed). If the VAD fails, [segments] closes with its error.
 * [closed] counts the segments cut so far; [processed], [heard] and [failed]
 * are for the no-speech watchdog (all read from any thread).
 */
class SegmentFeed(
    vad: () -> SpeechProbability,
    pauseMs: Int,
    maxSegmentSec: Int,
    scope: CoroutineScope,
    io: CoroutineDispatcher,
) {
    private val reads = Channel<ShortArray>(Channel.UNLIMITED)
    private val out = Channel<Segment>(Channel.UNLIMITED)
    val segments: ReceiveChannel<Segment> get() = out

    // Written on the VAD's thread only.
    @Volatile var closed = 0
        private set

    /** Samples the VAD has seen so far. */
    @Volatile var processed = 0L
        private set

    /** The VAD heard speech at least once. */
    @Volatile var heard = false
        private set

    /** The VAD failed: [heard] means nothing. */
    @Volatile var failed = false
        private set

    private val job = scope.launch(io) {
        try {
            vad().use { v ->
                val segmenter = Segmenter(v, pauseMs, maxSegmentSec)
                val framer = Framer()
                for (chunk in reads) {
                    framer.push(chunk) { frame ->
                        segmenter.feed(frame).forEach(::emit)
                        if (segmenter.speaking) heard = true
                    }
                    processed += chunk.size
                }
                segmenter.flush().forEach(::emit)
            }
            out.close()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            failed = true
            reads.cancel() // later reads are dropped, not queued
            out.close(e)
        }
    }

    private fun emit(segment: Segment) {
        heard = true
        closed++
        out.trySend(segment)
    }

    fun tap(samples: ShortArray, n: Int) {
        reads.trySend(samples.copyOf(n))
    }

    /** No more samples (the recorder stopped). */
    fun end() {
        reads.close()
    }

    fun cancel() {
        job.cancel()
        reads.close()
        out.cancel()
    }
}
