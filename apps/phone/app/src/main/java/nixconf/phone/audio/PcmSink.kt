package nixconf.phone.audio

// What AudioSource.start() writes PCM16 samples into: the recorder thread's
// only contract with whatever consumes the microphone (a WavWriter for
// dictation, a DiaryRecording for the diary). flush() is called periodically
// (and once at stop) so a killed app loses at most that much.
interface PcmSink {
    fun write(samples: ShortArray, n: Int)
    fun flush()
}
