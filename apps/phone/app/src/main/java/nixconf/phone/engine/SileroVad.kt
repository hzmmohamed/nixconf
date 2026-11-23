package nixconf.phone.engine

import android.content.res.AssetManager
import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadModelConfig
import java.io.IOException
import nixconf.phone.segment.FRAME
import nixconf.phone.segment.RATE
import nixconf.phone.segment.SpeechProbability

// Silero VAD v6 (the laptops' ONNX, bundled in the APK's assets by
// `phone-app`) through sherpa-onnx. Only Vad.compute is used: the model's raw
// probability for one window, with sherpa keeping the LSTM state; its own
// segment queue (acceptWaveform) is not, the Segmenter decides. As on the
// desktop (dictate-stream.py, Vad), each 512-sample frame goes in behind the
// last 64 samples of the previous one. One instance per recording.
class SileroVad(assets: AssetManager) : SpeechProbability {
    private val vad = Vad(
        assetManager = assets,
        config = VadModelConfig(
            sileroVadModelConfig = SileroVadModelConfig(model = ASSET, windowSize = FRAME),
            sampleRate = RATE,
            numThreads = 1,
        ),
    )
    private val input = FloatArray(CONTEXT + FRAME)

    override fun probability(frame: FloatArray): Float {
        System.arraycopy(frame, 0, input, CONTEXT, FRAME)
        val p = vad.compute(input)
        System.arraycopy(frame, FRAME - CONTEXT, input, 0, CONTEXT)
        return p
    }

    override fun close() = vad.release()

    companion object {
        private const val ASSET = "silero_vad.onnx"
        private const val CONTEXT = 64

        /** False in a build without the model (no -PvadAssets): sessions transcribe the whole recording. */
        fun bundled(assets: AssetManager): Boolean = try {
            assets.open(ASSET).close()
            true
        } catch (e: IOException) {
            false
        }
    }
}
