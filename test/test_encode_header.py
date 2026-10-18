"""Offline encoder/fixture regression checks; standard library plus the project's cast binary."""
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("encode_header", ROOT / "script/encode_header.py")
encoder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(encoder)


class HeaderEncoderTest(unittest.TestCase):
    def fixture(self):
        return json.loads((ROOT / "test/fixtures/sepolia-11921684.json").read_text())

    def test_all_real_fixtures_match_published_keccak(self):
        for path in sorted((ROOT / "test/fixtures").glob("*.json")):
            with self.subTest(path=path.name):
                block = json.loads(path.read_text())
                encoded = "0x" + encoder.encode(block).hex()
                digest = subprocess.check_output(["cast", "keccak", encoded], text=True).strip()
                self.assertEqual(digest, block["hash"])
                self.assertEqual(encoder.encode({"result": block}), encoder.encode(block))
                solidity = "SepoliaHeader.sol" if path.name.startswith("sepolia") else "MainnetHeaders.sol"
                self.assertIn(encoded[2:], (ROOT / "test/fixtures" / solidity).read_text())

    def test_new_fields_are_in_required_order_and_slot_is_a_quantity(self):
        block = self.fixture()
        self.assertEqual(encoder.TRAILING_FIELDS[-3:], ("requestsHash", "blockAccessListHash", "slotNumber"))
        self.assertIn("slotNumber", encoder.QUANTITIES)
        original = encoder.encode(block)
        del block["slotNumber"]
        self.assertNotEqual(original, encoder.encode(block))
        del block["blockAccessListHash"]
        self.assertNotEqual(original, encoder.encode(block))

    def test_unknown_fields_are_refused_including_null(self):
        for value in ("0x01", None):
            block = self.fixture()
            block["futureConsensusField"] = value
            with self.assertRaisesRegex(ValueError, "unsupported header fields"):
                encoder.encode(block)

    def test_gaps_in_fork_fields_are_refused(self):
        for field in encoder.TRAILING_FIELDS[:-1]:
            block = self.fixture()
            del block[field]
            with self.assertRaisesRegex(ValueError, "gap before"):
                encoder.encode(block)

    def test_metadata_is_ignored_but_negative_quantities_are_refused(self):
        block = self.fixture()
        before = encoder.encode(block)
        for field in ("transactions", "withdrawals", "uncles"):
            block[field] = []
        self.assertEqual(before, encoder.encode(block))
        block["slotNumber"] = -1
        with self.assertRaisesRegex(ValueError, "negative header quantity"):
            encoder.encode(block)


if __name__ == "__main__":
    unittest.main()
