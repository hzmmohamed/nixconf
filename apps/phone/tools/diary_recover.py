#!/usr/bin/env python3
"""diary_recover.py - offline recovery for Pollen's sealed diary entries.

Usage:
    python3 diary_recover.py --key recovery.pem --out DIR ENTRY_DIR...
    (or: nx --py cryptography -- apps/phone/tools/diary_recover.py ...)

Each ENTRY_DIR is one entry directory as written by EntryStore.kt
(<id>/meta.pdy or meta.pdy.tmp, and <id>/audio.pdy if it has audio - see
EntryCipher.kt for the exact sealed-file byte layout this tool parses).
--key is the recovery recipient's RSA private key, PEM (PKCS8, unencrypted).

For every entry recovered, this writes:
    DIR/<id>/meta.json   - the entry's decoded JSON (the meta.pdy frame, verbatim)
    DIR/<id>/audio.wav   - pcm_s16le audio, 16 kHz mono
    DIR/<id>/audio.ogg   - opus audio, rebuilt as an Ogg Opus stream from the
                           codecConfig (OpusHead payload) stored in meta.json

A frame that is short (truncated write), has a ciphertext length outside
16..MAX_FRAME_CT, or fails GCM authentication stops that file's recovery
there (as the phone's own reader does) - everything before it is kept, and
a warning goes to stderr. Exit code: 0 if at least the meta was recovered
for every ENTRY_DIR given; 1 if any entry's key could not be unwrapped with
this recovery key.
"""

import argparse
import base64
import json
import struct
import sys
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"PDY1"
ROLE_META = 1
ROLE_AUDIO = 2
MAX_FRAME_CT = 4_194_304
GCM_TAG_BYTES = 16
RECOVERY_PREFIX = "recovery:"

OAEP = padding.OAEP(mgf=padding.MGF1(algorithm=hashes.SHA256()), algorithm=hashes.SHA256(), label=None)


class UnwrapError(Exception):
    """No recipient with the given id prefix could be unwrapped with this key."""


# --- sealed file format (EntryCipher.kt) ------------------------------------


def read_header(f):
    """Parses the PDY1 header: magic, per-recipient wrapped keys, nonce prefix."""
    magic = f.read(4)
    if magic != MAGIC:
        raise ValueError("bad magic: not a sealed entry file")
    count = f.read(1)[0]
    recipients = {}
    for _ in range(count):
        id_len = f.read(1)[0]
        rid = f.read(id_len).decode("ascii")
        (wrapped_len,) = struct.unpack(">H", f.read(2))
        recipients[rid] = f.read(wrapped_len)
    nonce_prefix = f.read(4)
    return recipients, nonce_prefix


def unwrap_key(recipients, private_key, id_prefix):
    """RSA-OAEP-unwraps the 32-byte entry key from whichever recipient id starts with id_prefix."""
    last_error = None
    for rid, wrapped in recipients.items():
        if not rid.startswith(id_prefix):
            continue
        try:
            return private_key.decrypt(wrapped, OAEP)
        except Exception as e:  # noqa: BLE001 - any padding/key failure means "doesn't unwrap"
            last_error = e
    raise UnwrapError(str(last_error) if last_error else f"no recipient matches '{id_prefix}'")


def iter_frames(f, secret, nonce_prefix, role, warn):
    """Yields each frame's plaintext in order; stops (without raising) at the first
    frame that's short, out of range, or fails authentication - same contract as
    FrameReader in EntryCipher.kt."""
    aesgcm = AESGCM(secret)
    index = 0
    while True:
        len_bytes = f.read(4)
        if len(len_bytes) < 4:
            if len_bytes:
                warn(f"frame {index}: truncated length prefix, stopping")
            return
        (length,) = struct.unpack(">I", len_bytes)
        if length < GCM_TAG_BYTES or length > MAX_FRAME_CT:
            warn(f"frame {index}: length {length} out of range, stopping")
            return
        ct = f.read(length)
        if len(ct) < length:
            warn(f"frame {index}: truncated ciphertext ({len(ct)}/{length} bytes), stopping")
            return
        nonce = nonce_prefix + struct.pack(">Q", index)
        aad = MAGIC + bytes([role]) + struct.pack(">Q", index)
        try:
            yield aesgcm.decrypt(nonce, ct, aad)
        except Exception:  # noqa: BLE001 - bad tag, tampering, or out-of-order frames
            warn(f"frame {index}: failed to authenticate, stopping")
            return
        index += 1


def open_role(path: Path, private_key, role: int, warn):
    """Unwraps the entry key and concatenates every [role] frame's plaintext from path."""
    with path.open("rb") as f:
        recipients, nonce_prefix = read_header(f)
        secret = unwrap_key(recipients, private_key, RECOVERY_PREFIX)
        return b"".join(iter_frames(f, secret, nonce_prefix, role, warn))


# --- audio.wav / audio.ogg ----------------------------------------------------


def build_wav(pcm: bytes, sample_rate: int = 16000) -> bytes:
    """16-bit mono PCM WAV, matching WavFiles.header in audio/WavWriter.kt."""
    data_bytes = len(pcm)
    header = bytearray()
    header += b"RIFF"
    header += struct.pack("<I", 36 + data_bytes)
    header += b"WAVE"
    header += b"fmt "
    header += struct.pack("<I", 16)
    header += struct.pack("<H", 1)  # PCM
    header += struct.pack("<H", 1)  # mono
    header += struct.pack("<I", sample_rate)
    header += struct.pack("<I", sample_rate * 2)  # byte rate
    header += struct.pack("<H", 2)  # block align
    header += struct.pack("<H", 16)  # bits per sample
    header += b"data"
    header += struct.pack("<I", data_bytes)
    return bytes(header) + pcm


def unpack_opus_packets(data: bytes, warn) -> list:
    """Splits ROLE_AUDIO opus frame plaintext into packets: a sequence of u16 (big-endian)
    length | packet, our own convention (Task 5 is the writer)."""
    packets = []
    off = 0
    while off < len(data):
        if off + 2 > len(data):
            warn("trailing byte after last opus packet, ignoring")
            break
        (length,) = struct.unpack_from(">H", data, off)
        off += 2
        if off + length > len(data):
            warn("truncated opus packet, ignoring")
            break
        packets.append(data[off : off + length])
        off += length
    return packets


# Ogg's CRC-32: polynomial 0x04C11DB7, unreflected, init 0, no final xor
# (not the same algorithm as zlib.crc32 - that one is reflected).
def _build_crc_table():
    table = []
    for i in range(256):
        r = i << 24
        for _ in range(8):
            r = ((r << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if r & 0x80000000 else (r << 1) & 0xFFFFFFFF
        table.append(r)
    return table


_CRC_TABLE = _build_crc_table()


def ogg_crc(data: bytes) -> int:
    crc = 0
    for b in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ _CRC_TABLE[((crc >> 24) & 0xFF) ^ b]
    return crc & 0xFFFFFFFF


def _lacing(n: int) -> list:
    segs = []
    while n >= 255:
        segs.append(255)
        n -= 255
    segs.append(n)
    return segs


def _ogg_page(serial: int, seq: int, granulepos: int, header_type: int, packets: list) -> bytes:
    """One Ogg page carrying [packets] (one packet per page is the common case here)."""
    segments = []
    for p in packets:
        segments.extend(_lacing(len(p)))
    if len(segments) > 255:
        raise ValueError("too many segments for one Ogg page")
    header = bytearray()
    header += b"OggS"
    header.append(0)  # stream structure version
    header.append(header_type)
    header += struct.pack("<q", granulepos)
    header += struct.pack("<I", serial)
    header += struct.pack("<I", seq)
    header += b"\x00\x00\x00\x00"  # CRC placeholder, filled in below
    header.append(len(segments))
    header += bytes(segments)
    page = bytes(header) + b"".join(packets)
    crc = ogg_crc(page)
    return page[:22] + struct.pack("<I", crc) + page[26:]


# Opus packet frame duration in samples at 48 kHz, by TOC config (RFC 6716 ss3.1).
_SILK_SAMPLES = [480, 960, 1920, 2880]  # NB/MB/WB x {10,20,40,60} ms
_HYBRID_SAMPLES = [480, 960]  # SWB/FB x {10,20} ms
_CELT_SAMPLES = [120, 240, 480, 960]  # NB/WB/SWB/FB x {2.5,5,10,20} ms


def opus_packet_duration_samples(packet: bytes) -> int:
    if not packet:
        return 0
    toc = packet[0]
    config = toc >> 3
    frame_count_code = toc & 0x3
    if config <= 11:
        per_frame = _SILK_SAMPLES[config % 4]
    elif config <= 15:
        per_frame = _HYBRID_SAMPLES[config % 2]
    else:
        per_frame = _CELT_SAMPLES[config % 4]
    if frame_count_code == 0:
        num_frames = 1
    elif frame_count_code in (1, 2):
        num_frames = 2
    else:
        num_frames = (packet[1] & 0x3F) if len(packet) > 1 else 0
    return per_frame * num_frames


def build_ogg_opus(packets: list, codec_config: bytes, serial: int = 0x50444959) -> bytes:
    """An Ogg Opus stream: the stored OpusHead, a minimal OpusTags, then one page per packet."""
    out = bytearray()
    out += _ogg_page(serial, 0, 0, 0x02, [codec_config])  # BOS
    vendor = b"diary_recover"
    tags = b"OpusTags" + struct.pack("<I", len(vendor)) + vendor + struct.pack("<I", 0)
    out += _ogg_page(serial, 1, 0, 0x04 if not packets else 0x00, [tags])
    granule = 0
    for i, packet in enumerate(packets):
        granule += opus_packet_duration_samples(packet)
        header_type = 0x04 if i == len(packets) - 1 else 0x00
        out += _ogg_page(serial, i + 2, granule, header_type, [packet])
    return bytes(out)


# --- per-entry recovery --------------------------------------------------------


def recover_entry(entry_dir: Path, private_key, out_root: Path, warn) -> bool:
    """Recovers one entry into out_root/<id>/. Returns True iff meta was recovered."""
    entry_id = entry_dir.name
    meta_path = entry_dir / "meta.pdy"
    if not meta_path.is_file():
        meta_path = entry_dir / "meta.pdy.tmp"
    if not meta_path.is_file():
        warn(f"{entry_id}: no meta.pdy or meta.pdy.tmp")
        return False

    def meta_warn(msg):
        warn(f"{entry_id}: {msg}")

    try:
        meta_bytes = open_role(meta_path, private_key, ROLE_META, meta_warn)
    except UnwrapError:
        print("cannot unwrap entry key with this recovery key", file=sys.stderr)
        return False
    except Exception as e:  # noqa: BLE001 - header parse failure etc.
        meta_warn(f"meta unreadable ({e})")
        return False

    if not meta_bytes:
        meta_warn("meta frame missing or failed to decrypt")
        return False

    out_dir = out_root / entry_id
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "meta.json").write_bytes(meta_bytes)

    audio_path = entry_dir / "audio.pdy"
    if audio_path.is_file():
        try:
            meta = json.loads(meta_bytes)
        except json.JSONDecodeError:
            meta = {}

        try:
            frame_bytes = open_role(audio_path, private_key, ROLE_AUDIO, meta_warn)
        except UnwrapError:
            meta_warn("cannot unwrap audio key with this recovery key")
            frame_bytes = b""
        except Exception as e:  # noqa: BLE001
            meta_warn(f"audio unreadable ({e})")
            frame_bytes = b""

        if frame_bytes:
            if meta.get("codec") == "opus":
                packets = unpack_opus_packets(frame_bytes, meta_warn)
                codec_config = base64.b64decode(meta["codecConfig"]) if meta.get("codecConfig") else b""
                (out_dir / "audio.ogg").write_bytes(build_ogg_opus(packets, codec_config))
            else:
                (out_dir / "audio.wav").write_bytes(build_wav(frame_bytes))

    return True


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--key", required=True, type=Path, help="recovery recipient's private key, PEM")
    parser.add_argument("--out", required=True, type=Path, help="output directory")
    parser.add_argument("entry_dirs", nargs="+", type=Path, metavar="ENTRY_DIR")
    args = parser.parse_args(argv)

    private_key = serialization.load_pem_private_key(args.key.read_bytes(), password=None)

    def warn(msg):
        print(f"warning: {msg}", file=sys.stderr)

    all_recovered = True
    for entry_dir in args.entry_dirs:
        if not recover_entry(Path(entry_dir), private_key, args.out, warn):
            all_recovered = False

    return 0 if all_recovered else 1


if __name__ == "__main__":
    sys.exit(main())
