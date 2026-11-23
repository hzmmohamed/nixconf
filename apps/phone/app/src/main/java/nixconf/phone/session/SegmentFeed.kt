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
 */
class SegmentFeed(
    vad: () -> SpeechProbability,
    pauseMs: Int,
    maxSegmentSec: Int,
    scope: CoroutineScope,
    io: CoroutineDispatcher,
) {
    private val reads = Channel<ShortArray>(Channel.UNLIMITED)
    private val closed = Channel<Segment>(Channel.UNLIMITED)
    val segments: ReceiveChannel<Segment> get() = closed

    private val job = scope.launch(io) {
        try {
            vad().use { v ->
                val segmenter = Segmenter(v, pauseMs, maxSegmentSec)
                val framer = Framer()
                for (chunk in reads) {
                    framer.push(chunk) { frame -> segmenter.feed(frame).forEach { closed.trySend(it) } }
                }
                segmenter.flush().forEach { closed.trySend(it) }
            }
            closed.close()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            reads.cancel() // later reads are dropped, not queued
            closed.close(e)
        }
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
        closed.cancel()
    }
}
