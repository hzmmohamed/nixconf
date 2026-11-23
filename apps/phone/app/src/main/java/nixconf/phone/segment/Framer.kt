package nixconf.phone.segment

/** Cuts the recorder's reads (any length, PCM16) into [FRAME]-sample frames in -1..1; a partial frame waits for more. */
class Framer {
    private var frame = FloatArray(FRAME)
    private var fill = 0

    fun push(samples: ShortArray, n: Int = samples.size, out: (FloatArray) -> Unit) {
        for (i in 0 until n) {
            frame[fill++] = samples[i] / 32768f
            if (fill == FRAME) {
                out(frame)
                frame = FloatArray(FRAME)
                fill = 0
            }
        }
    }
}
