package nixconf.phone.diary

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.StandardOpenOption
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

/** fsyncs [dir] itself, so a rename or a new file inside it survives a crash right after. */
private fun fsyncDir(dir: File) {
    FileChannel.open(dir.toPath(), StandardOpenOption.READ).use { it.force(true) }
}

/**
 * One EntryStore per process, shared by every caller: [activeId] is in-memory only (not
 * persisted), so it only means anything as long as the same instance stays alive - that's what
 * lets a fresh instance (after a kill) see a Recording entry nobody is writing to any more as
 * [State.Interrupted] (see [list], [openForRead]). All meta reads/writes for a given entry are
 * serialized through [metaLock] so two callers (e.g. the recording thread doing [OpenEntry.update]
 * and the UI thread calling [setHidden]) never race on the same meta.pdy.tmp.
 */
class EntryStore(private val root: File, private val recipients: () -> List<Recipient>, private val now: () -> Long) {
    /** The entry currently being recorded, if any. [list]/[openForRead] skip/un-interrupt it. */
    @Volatile var activeId: String? = null

    /** Serializes every meta read-modify-write and every meta write, across all entries. */
    private val metaLock = Any()

    /** Test seam: lets a test inject a stream that fails partway through a write. Production default. */
    internal var openAudioStream: (File) -> FileOutputStream = { f -> FileOutputStream(f) }

    /** Starts a new entry: makes its directory and seals the initial meta. Needs only public keys. */
    fun create(kind: Kind, codec: Codec, zone: String): OpenEntry {
        val recordedAt = now()
        val entry = Entry(
            id = Ulid.next(recordedAt),
            recordedAt = recordedAt,
            zone = zone,
            kind = kind,
            codec = codec,
            state = State.Recording,
        )
        val dir = File(root, entry.id)
        if (!dir.mkdirs()) throw IOException("cannot create $dir")
        fsyncDir(root)
        // Set before the first write so a concurrent list()/openForRead() never sees this id
        // as unattended (Interrupted) while it is, in fact, about to be written.
        activeId = entry.id
        writeMeta(dir, entry)
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

    /**
     * Opens an existing entry for reading; needs the private key once, to decode its meta. Agrees
     * with [list]: an entry stored Recording with no live writer ([id] != [activeId]) comes back
     * Interrupted in memory. That's not persisted unless the caller calls [ReadEntry.update].
     */
    fun openForRead(id: String, privateKey: PrivateKey): ReadEntry {
        val dir = File(root, id)
        val entry = readMeta(dir, privateKey)
        val reported = if (entry.state == State.Recording && id != activeId) entry.copy(state = State.Interrupted) else entry
        return ReadEntry(reported, dir, privateKey)
    }

    /** Flags [id] hidden (or unhides it). Reads meta with [privateKey], re-seals it with a fresh key. */
    fun setHidden(id: String, hidden: Boolean, privateKey: PrivateKey) {
        val dir = File(root, id)
        synchronized(metaLock) {
            writeMeta(dir, readMeta(dir, privateKey).copy(hidden = hidden))
        }
    }

    /** Re-seals [entry] into [dir]/meta.pdy with a fresh key: write .tmp, fsync, rename, fsync dir. Public keys only. */
    private fun writeMeta(dir: File, entry: Entry) {
        synchronized(metaLock) {
            val key = EntryKey.new(recipients())
            val tmp = File(dir, META_TMP)
            FileOutputStream(tmp).use { out ->
                out.write(key.header())
                val plain = DiaryJson.encodeToString(Entry.serializer(), entry).toByteArray(Charsets.UTF_8)
                FrameWriter(out, key, ROLE_META).write(plain)
                out.fd.sync()
            }
            if (!tmp.renameTo(File(dir, META_FILE))) throw IOException("cannot write $dir/$META_FILE")
            fsyncDir(dir)
        }
    }

    /**
     * Decodes meta.pdy, or - if it's missing but a meta.pdy.tmp from an interrupted rewrite is
     * still there and itself decodes - meta.pdy.tmp. A meta.pdy.tmp next to a *good* meta.pdy
     * (a stale leftover from an earlier crash) is never consulted: meta.pdy always wins when
     * it's there, so a half-written-then-abandoned .tmp can't shadow the last good meta.
     */
    private fun readMeta(dir: File, privateKey: PrivateKey): Entry {
        val metaFile = File(dir, META_FILE)
        if (metaFile.isFile) return decodeMeta(metaFile, privateKey)
        val tmp = File(dir, META_TMP)
        if (tmp.isFile) return decodeMeta(tmp, privateKey)
        throw IOException("no meta file in $dir")
    }

    private fun decodeMeta(file: File, privateKey: PrivateKey): Entry =
        FileInputStream(file).use { input ->
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

        /** Set once a frame write or sync fails; every later call fails fast instead of retrying. */
        @Volatile private var failed = false

        /**
         * Seals and appends one audio frame, fsyncing it; opens audio.pdy lazily on the first call.
         * On any failure mid-write (e.g. disk full), the file is truncated back to the position it
         * had before this call - so a half-written frame never lingers to confuse the next read -
         * and the entry is marked failed: nothing it writes again could use a fresh, unused frame
         * index without risking nonce reuse against what's already on disk, so there is no retry.
         */
        fun appendAudio(chunk: ByteArray) {
            if (failed) throw IOException("entry closed after a write failure")
            if (audioWriter == null) {
                val key = EntryKey.new(recipients())
                val out = openAudioStream(File(dir, AUDIO_FILE))
                try {
                    out.write(key.header())
                    out.fd.sync()
                } catch (e: Exception) {
                    failed = true
                    closeQuietly(out)
                    throw e
                }
                fsyncDir(dir)
                audioOut = out
                audioWriter = FrameWriter(out, key, ROLE_AUDIO)
            }
            val out = audioOut!!
            val writer = audioWriter!!
            val pos = out.channel.position()
            try {
                writer.write(chunk)
                out.fd.sync()
            } catch (e: Exception) {
                failed = true
                try {
                    out.channel.truncate(pos)
                    out.fd.sync()
                } catch (truncateFailed: Exception) {
                    // Best effort: the write failure itself is what the caller needs to see.
                }
                throw e
            }
        }

        /** Applies [f] to the in-memory entry and re-seals meta from the result, atomically. No private key needed. */
        fun update(f: (Entry) -> Entry) {
            synchronized(metaLock) {
                entry = f(entry)
                writeMeta(dir, entry)
            }
        }

        /** Marks the entry Done. Closes audio.pdy and clears [activeId] (if it was this entry) even if the meta write fails. */
        fun finish(durationMs: Long) {
            try {
                update { it.copy(state = State.Done, durationMs = durationMs) }
            } finally {
                audioOut?.let { closeQuietly(it) }
                if (activeId == entry.id) activeId = null
            }
        }
    }

    /** An existing entry opened for reading. Re-seals its own meta on [update]; needs no private key for that. */
    inner class ReadEntry internal constructor(entry: Entry, private val dir: File, private val privateKey: PrivateKey) {
        var entry: Entry = entry
            private set

        /**
         * Runs [block] over the entry's audio frames, in order, streamed lazily off the open
         * file (never all buffered in memory at once - a long recording stays cheap to read).
         * The file is closed as soon as [block] returns or throws; [block] must consume the
         * sequence before returning. No audio.pdy (e.g. a typed entry) means an empty sequence.
         */
        fun <T> useAudioFrames(block: (Sequence<ByteArray>) -> T): T {
            val file = File(dir, AUDIO_FILE)
            if (!file.isFile) return block(emptySequence())
            return FileInputStream(file).use { input ->
                val header = readHeader(input)
                val key = EntryKey.open(header, privateKey, DEVICE_PREFIX)
                block(FrameReader(input, key, ROLE_AUDIO).asSequence())
            }
        }

        /** Applies [f] to the in-memory entry and re-seals meta from the result, atomically. No private key needed. */
        fun update(f: (Entry) -> Entry) {
            synchronized(metaLock) {
                entry = f(entry)
                writeMeta(dir, entry)
            }
        }
    }
}

private fun closeQuietly(out: FileOutputStream) {
    try {
        out.close()
    } catch (e: IOException) {
        // Already failing; closing is best-effort.
    }
}
