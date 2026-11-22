package nixconf.phone.engine

import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineTransducerModelConfig
import java.io.File
import java.io.IOException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import nixconf.phone.audio.WavFiles
import nixconf.phone.session.LocalTranscriber

// On-phone Parakeet (sherpa-onnx), as on the laptops (dictate-local.py):
// NeMo TDT transducer, greedy search, English. [modelDir] is the verified
// model directory, or null while it is not downloaded. The recognizer (~1 GB
// of RAM) is loaded on first use and released after [idleMs] without use.
class LocalEngine(
    private val modelDir: () -> File?,
    private val scope: CoroutineScope,
    private val idleMs: Long = 5 * 60_000,
) : LocalTranscriber {
    override val ready: Boolean get() = modelDir() != null

    private val lock = Any()
    private var recognizer: OfflineRecognizer? = null
    private var loadedFrom: File? = null
    private var lastUsed = 0L
    private var releaser: Job? = null

    override fun transcribe(wav: File): String = synchronized(lock) {
        val dir = modelDir() ?: throw IOException("on-phone model not downloaded")
        try {
            val rec = recognizer.takeIf { loadedFrom == dir } ?: load(dir)
            val samples = WavFiles.readSamples(wav)
            val floats = FloatArray(samples.size) { samples[it] / 32768f }
            val stream = rec.createStream()
            try {
                stream.acceptWaveform(floats, SAMPLE_RATE)
                rec.decode(stream)
                rec.getResult(stream).text
            } finally {
                stream.release()
            }
        } finally {
            lastUsed = System.currentTimeMillis()
            scheduleRelease()
        }
    }

    private fun load(dir: File): OfflineRecognizer {
        releaseLocked()
        val config = OfflineRecognizerConfig(
            modelConfig = OfflineModelConfig(
                transducer = OfflineTransducerModelConfig(
                    encoder = File(dir, "encoder.int8.onnx").path,
                    decoder = File(dir, "decoder.int8.onnx").path,
                    joiner = File(dir, "joiner.int8.onnx").path,
                ),
                tokens = File(dir, "tokens.txt").path,
                modelType = "nemo_transducer",
                numThreads = 4,
            ),
            decodingMethod = "greedy_search",
        )
        // No AssetManager: the files are read from the app's storage.
        return OfflineRecognizer(config = config).also {
            recognizer = it
            loadedFrom = dir
        }
    }

    private fun scheduleRelease() {
        releaser?.cancel()
        releaser = scope.launch(Dispatchers.IO) {
            delay(idleMs)
            synchronized(lock) {
                if (System.currentTimeMillis() - lastUsed >= idleMs) releaseLocked()
            }
        }
    }

    private fun releaseLocked() {
        recognizer?.release()
        recognizer = null
        loadedFrom = null
    }

    private companion object {
        const val SAMPLE_RATE = 16000
    }
}
