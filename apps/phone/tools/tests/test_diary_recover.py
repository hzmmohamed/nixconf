"""Tests for diary_recover.py against the committed golden fixture.

Run from the repo root with:
    nx --py cryptography -- -m unittest discover -s apps/phone/tools/tests
"""

import json
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# diary_recover.py lives one directory up; unittest discover only adds the
# start directory (this one) to sys.path, so add its parent explicitly.
TOOLS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS_DIR))

import diary_recover  # noqa: E402

GOLDEN = TOOLS_DIR.parent / "app" / "src" / "test" / "resources" / "diary" / "golden"
RECOVERY_KEY = GOLDEN / "recovery_test_key.pem"


def _entry_dir() -> Path:
    dirs = [p for p in GOLDEN.iterdir() if p.is_dir()]
    assert len(dirs) == 1, f"expected exactly one entry dir under {GOLDEN}, found {dirs}"
    return dirs[0]


class DiaryRecoverTest(unittest.TestCase):
    def setUp(self):
        self.out = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.out, ignore_errors=True)

    def test_recovers_golden(self):
        rc = diary_recover.main(["--key", str(RECOVERY_KEY), "--out", str(self.out), str(_entry_dir())])
        self.assertEqual(0, rc)

        entry_id = _entry_dir().name
        meta = (self.out / entry_id / "meta.json").read_bytes()
        expected_meta = (GOLDEN / "expected_meta.json").read_bytes()
        self.assertEqual(expected_meta, meta)

        wav = (self.out / entry_id / "audio.wav").read_bytes()
        # 44-byte WAV header + 16-bit mono samples.
        self.assertEqual(b"RIFF", wav[0:4])
        self.assertEqual(b"WAVE", wav[8:12])
        data_len = struct.unpack("<I", wav[40:44])[0]
        self.assertEqual(16000, data_len // 2)

    def test_truncated_audio_keeps_first_frame(self):
        entry_id = _entry_dir().name
        tmp_entry = self.out / "src" / entry_id
        shutil.copytree(_entry_dir(), tmp_entry)
        audio_path = tmp_entry / "audio.pdy"
        truncated = audio_path.read_bytes()[:-3]
        audio_path.write_bytes(truncated)

        result = subprocess.run(
            [sys.executable, str(TOOLS_DIR / "diary_recover.py"), "--key", str(RECOVERY_KEY), "--out", str(self.out / "dst"), str(tmp_entry)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(0, result.returncode)
        self.assertIn("warning", result.stderr.lower())

        wav = (self.out / "dst" / entry_id / "audio.wav").read_bytes()
        data_len = struct.unpack("<I", wav[40:44])[0]
        # The two source frames are 16000 bytes (8000 samples) each; truncating the
        # tail of the second frame's ciphertext drops it entirely, keeping only the first.
        self.assertEqual(8000, data_len // 2)

    def test_wrong_key_fails_clearly(self):
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import rsa

        other_key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
        other_pem = self.out / "other.pem"
        other_pem.write_bytes(
            other_key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.NoEncryption(),
            )
        )

        result = subprocess.run(
            [sys.executable, str(TOOLS_DIR / "diary_recover.py"), "--key", str(other_pem), "--out", str(self.out / "dst"), str(_entry_dir())],
            capture_output=True,
            text=True,
        )
        self.assertEqual(1, result.returncode)
        self.assertIn("cannot unwrap entry key with this recovery key", result.stderr)

    def test_ogg_opus_page_crc(self):
        # Two tiny synthetic Opus packets (content doesn't matter for page structure).
        packets = [bytes([0x08, 0xFF, 0x00, 0x01]), bytes([0x08, 0x02, 0x03])]
        codec_config = b"OpusHead" + bytes([1, 1]) + struct.pack("<H", 0) + struct.pack("<I", 48000) + struct.pack("<h", 0) + bytes([0])
        ogg = diary_recover.build_ogg_opus(packets, codec_config)

        pages = _split_ogg_pages(ogg)
        self.assertEqual(4, len(pages))  # OpusHead, OpusTags, 2 data pages
        self.assertEqual(b"OggS", pages[0][0:4])
        self.assertTrue(pages[0][28:].startswith(b"OpusHead"))
        self.assertTrue(_payload(pages[1]).startswith(b"OpusTags"))
        self.assertEqual(_payload(pages[2]), packets[0])
        self.assertEqual(_payload(pages[3]), packets[1])

        # First page is BOS (0x02); last page is EOS (0x04).
        self.assertEqual(0x02, pages[0][5])
        self.assertEqual(0x04, pages[-1][5])

        for page in pages:
            stored_crc = struct.unpack("<I", page[22:26])[0]
            zeroed = page[:22] + b"\x00\x00\x00\x00" + page[26:]
            self.assertEqual(stored_crc, diary_recover.ogg_crc(zeroed))


def _split_ogg_pages(data: bytes):
    pages = []
    off = 0
    while off < len(data):
        assert data[off : off + 4] == b"OggS"
        nseg = data[off + 26]
        seg_table = data[off + 27 : off + 27 + nseg]
        body_len = sum(seg_table)
        page_len = 27 + nseg + body_len
        pages.append(data[off : off + page_len])
        off += page_len
    return pages


def _payload(page: bytes) -> bytes:
    nseg = page[26]
    seg_table = page[27 : 27 + nseg]
    body_len = sum(seg_table)
    return page[27 + nseg : 27 + nseg + body_len]


if __name__ == "__main__":
    unittest.main()
