package nixconf.phone.diary

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.security.PrivateKey

// One directory per entry: <root>/<id>/meta.pdy and <root>/<id>/audio.pdy
// (sealed; audio only present once a frame has been written). Each file
// carries its own header and its own entry key: meta is re-sealed with a
// fresh key on every write (header + exactly one ROLE_META frame, written
// to meta.pdy.tmp, fsynced, renamed over meta.pdy); audio keeps the key it
// was created with for the life of the recording. A key from EntryKey.open
// is decrypt-only (see EntryCipher), so reading meta to change it (update,
// setHidden) needs the private key only to read the current value - writing
// it back always goes through a fresh EntryKey.new, i.e. public keys only.

private const val META_FILE = "meta.pdy"
private const val META_TMP = "meta.pdy.tmp"
private const val AUDIO_FILE = "audio.pdy"
private const val DEVICE_PREFIX = "device:"

/** One entry as [EntryStore.list] sees it: either its decoded [entry], or [error] when meta couldn't be opened. */
data class Listed(val entry: Entry?, val id: String, val error: String?)

class EntryStore(private val root: File, private val recipients: () -> List<Recipient>, private val now: () -> Long) {
    /** The entry currently being recorded, if any. [list] skips it and never reports it Interrupted. */
    var activeId: String? = null

    /** Starts a new entry: makes its directory and seals the initial meta. Needs only public keys. */
    fun create(kind: Kind, codec: Codec, zone: String): OpenEntry {
        val entry = Entry(
            id = Ulid.next(now()),
            recordedAt = now(),
            zone = zone,
            kind = kind,
            codec = codec,
            state = State.Recording,
        )
        val dir = File(root, entry.id)
        if (!dir.mkdirs()) throw IOException("cannot create $dir")
        writeMeta(dir, entry)
        activeId = entry.id
        return OpenEntry(entry, dir)
    }

    /**
     * Every entry dir under [root] except [activeId] (that one has its own live state, held by
     * its [OpenEntry]). An entry whose meta is unreadable is still listed, with [Listed.error] set
     * instead of [Listed.entry]. An entry whose stored state is still Recording has no live writer
     * here (this is a fresh [EntryStore], or it would be [activeId]): reported Interrupted, though
     * the file on disk is left as Recording - a later writer may still resume it.
     */
    fun list(privateKey: PrivateKey): List<Listed> {
        val dirs = root.listFiles { f -> f.isDirectory } ?: emptyArray()
        return dirs.filter { it.name != activeId }.map { dir ->
            try {
                val entry = readMeta(dir, privateKey)
                val reported = if (entry.state == State.Recording) entry.copy(state = State.Interrupted) else entry
                Listed(reported, dir.name, null)
            } catch (e: Exception) {
                Listed(null, dir.name, "meta unreadable: ${e.javaClass.simpleName}")
            }
        }
    }

    /** Opens an existing entry for reading; needs the private key once, to decode its meta. */
    fun openForRead(id: String, privateKey: PrivateKey): ReadEntry {
        val dir = File(root, id)
        return ReadEntry(readMeta(dir, privateKey), dir, privateKey)
    }

    /** Flags [id] hidden (or unhides it). Reads meta with [privateKey], re-seals it with a fresh key. */
    fun setHidden(id: String, hidden: Boolean, privateKey: PrivateKey) {
        val dir = File(root, id)
        writeMeta(dir, readMeta(dir, privateKey).copy(hidden = hidden))
    }

    /** Re-seals [entry] into [dir]/meta.pdy with a fresh key: write .tmp, fsync, rename. Public keys only. */
    private fun writeMeta(dir: File, entry: Entry) {
        val key = EntryKey.new(recipients())
        val tmp = File(dir, META_TMP)
        FileOutputStream(tmp).use { out ->
            out.write(key.header())
            val plain = DiaryJson.encodeToString(Entry.serializer(), entry).toByteArray(Charsets.UTF_8)
            FrameWriter(out, key, ROLE_META).write(plain)
            out.fd.sync()
        }
        if (!tmp.renameTo(File(dir, META_FILE))) throw IOException("cannot write $dir/$META_FILE")
    }

    /** Opens [dir]/meta.pdy and decodes its single frame. Throws if the file is missing, corrupt or empty. */
    private fun readMeta(dir: File, privateKey: PrivateKey): Entry =
        FileInputStream(File(dir, META_FILE)).use { input ->
            val header = readHeader(input)
            val key = EntryKey.open(header, privateKey, DEVICE_PREFIX)
            val reader = FrameReader(input, key, ROLE_META)
            if (!reader.hasNext()) throw IOException("meta has no frame")
            DiaryJson.decodeFromString(Entry.serializer(), String(reader.next(), Charsets.UTF_8))
        }

    /** A newly-created entry, still being recorded. Re-seals its own meta; needs no private key. */
    inner class OpenEntry internal constructor(entry: Entry, private val dir: File) {
        var entry: Entry = entry
            private set
        private var audioOut: FileOutputStream? = null
        private var audioWriter: FrameWriter? = null

        /** Seals and appends one audio frame, fsyncing it; opens audio.pdy lazily on the first call. */
        fun appendAudio(chunk: ByteArray) {
            if (audioWriter == null) {
                val key = EntryKey.new(recipients())
                val out = FileOutputStream(File(dir, AUDIO_FILE))
                out.write(key.header())
                audioOut = out
                audioWriter = FrameWriter(out, key, ROLE_AUDIO)
            }
            audioWriter!!.write(chunk)
            audioOut!!.fd.sync()
        }

        /** Applies [f] to the in-memory entry and re-seals meta from the result. No private key needed. */
        fun update(f: (Entry) -> Entry) {
            entry = f(entry)
            writeMeta(dir, entry)
        }

        /** Marks the entry Done and closes audio.pdy (if any). Clears [activeId] once this was it. */
        fun finish(durationMs: Long) {
            update { it.copy(state = State.Done, durationMs = durationMs) }
            audioOut?.close()
            if (activeId == entry.id) activeId = null
        }
    }

    /** An existing entry opened for reading. Re-seals its own meta on [update]; needs no private key for that. */
    inner class ReadEntry internal constructor(entry: Entry, private val dir: File, private val privateKey: PrivateKey) {
        var entry: Entry = entry
            private set

        /** The entry's audio frames in order, or none if it has no audio.pdy (e.g. a typed entry). */
        fun audioFrames(): Iterator<ByteArray> {
            val file = File(dir, AUDIO_FILE)
            if (!file.isFile) return emptyList<ByteArray>().iterator()
            return FileInputStream(file).use { input ->
                val header = readHeader(input)
                val key = EntryKey.open(header, privateKey, DEVICE_PREFIX)
                FrameReader(input, key, ROLE_AUDIO).asSequence().toList()
            }.iterator()
        }

        /** Applies [f] to the in-memory entry and re-seals meta from the result. No private key needed. */
        fun update(f: (Entry) -> Entry) {
            entry = f(entry)
            writeMeta(dir, entry)
        }
    }
}
