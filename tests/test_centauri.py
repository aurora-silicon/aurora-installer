# SPDX-License-Identifier: MIT
"""N1 (Centauri) firmware on synthetic images and tickets, no Apple files."""
import contextlib, hashlib, io, pathlib, sys, tarfile, tempfile, unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from asahi_firmware import centauri, update  # noqa: E402

# An FTAB-shaped header (magic at 0x20, no ticket) and a few payload bytes.
IMAGE = bytes(0x20) + b"rkosftab" + (1).to_bytes(4, "little") + bytes(4) + b"synthetic N1 image"
# SEQUENCE { IA5String "IM4M", INTEGER 0 }
TICKET = bytes([0x30, 0x09, 0x16, 0x04]) + b"IM4M" + bytes([0x02, 0x01, 0x00])
# The same vector as CentauriFirmwareTests.swift.
PERSONALIZED_SHA256 = "82f9fbcd0c2f700dde10f373f7b1d4aacae2bb0e20357dd2e78e1b8745f660af"


def long_ticket(payload=200):
    body = bytes([0x16, 0x04]) + b"IM4M" + bytes([0x04, 0x81, payload]) + bytes(payload)
    return bytes([0x30, 0x81, len(body)]) + body


class PersonalizeTest(unittest.TestCase):
    def test_the_ticket_is_appended_and_named_in_the_header(self):
        out = centauri.personalize(IMAGE, TICKET)
        self.assertEqual(len(out), len(IMAGE) + len(TICKET))
        self.assertEqual(int.from_bytes(out[0x10:0x14], "little"), len(IMAGE))
        self.assertEqual(int.from_bytes(out[0x14:0x18], "little"), len(TICKET))
        self.assertEqual(out[len(IMAGE):], TICKET)
        self.assertEqual(out[:0x10], IMAGE[:0x10])
        self.assertEqual(out[0x18:len(IMAGE)], IMAGE[0x18:])
        self.assertEqual(hashlib.sha256(out).hexdigest(), PERSONALIZED_SHA256)

    def test_a_long_form_ticket_is_accepted(self):
        ticket = long_ticket()
        out = centauri.personalize(IMAGE, ticket)
        self.assertEqual(out[len(IMAGE):], ticket)

    def test_images_the_driver_would_refuse_are_refused(self):
        for image in (IMAGE[:0x2f],                                  # shorter than the header
                      IMAGE[:0x20] + b"rkosfta_" + IMAGE[0x28:],      # not an FTAB
                      IMAGE[:0x10] + (0x40).to_bytes(4, "little") + IMAGE[0x14:],  # has a ticket
                      IMAGE[:0x14] + (1).to_bytes(4, "little") + IMAGE[0x18:]):
            with self.assertRaises(centauri.Invalid):
                centauri.personalize(image, TICKET)

    def test_tickets_that_are_not_one_manifest_are_refused(self):
        for ticket in (b"", TICKET[1:], TICKET + b"\0",
                       TICKET[:4] + b"IM4P" + TICKET[8:],
                       bytes([0x30, 0x81, 0x05]) + TICKET[2:7],     # noncanonical length
                       bytes([0x30, 0x03, 0x02, 0x01, 0x00])):        # no IM4M string
            with self.assertRaises(centauri.Invalid):
                centauri.personalize(IMAGE, ticket)

    def test_the_driver_budget_is_kept(self):
        with mock.patch.object(centauri, "BUDGET", len(IMAGE) + len(TICKET) - 1):
            with self.assertRaises(centauri.Invalid):
                centauri.personalize(IMAGE, TICKET)


class NamesTest(unittest.TestCase):
    def test_each_model_gets_the_name_its_driver_requests(self):
        self.assertEqual(centauri.firmware_name("j714s"), "apple/centauri/j714s-ftab.bin")
        self.assertEqual(centauri.firmware_name("k116s"), "apple/centauri/k116s-ftab.bin")
        self.assertEqual(centauri.firmware_name("j813"), "apple/centauri/j813-ftab.bin")
        self.assertEqual(centauri.firmware_name("j873g"), "apple/centauri/j873-ftab.bin")
        self.assertEqual(centauri.ticket_name("j714s"), "centauri.j714sap.im4m")

    def test_owned_names(self):
        self.assertTrue(centauri.owned("apple/centauri/j714s-ftab.bin"))
        self.assertTrue(centauri.owned("apple/centauri/j873-ftab.bin"))
        self.assertFalse(centauri.owned("apple/centauri/ftab.bin"))
        self.assertFalse(centauri.owned("brcm/brcmfmac4388c2-pcie.bin"))


class CollectionTest(unittest.TestCase):
    def tree(self, tmp, models, ticket=True):
        root = pathlib.Path(tmp) / "centauri"
        for model in models:
            (root / model).mkdir(parents=True)
            (root / model / centauri.IMAGE).write_bytes(IMAGE)
            if ticket:
                (root / model / centauri.ticket_name(model)).write_bytes(TICKET)
        return str(root)

    def test_each_model_directory_becomes_its_driver_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            files = dict(centauri.CentauriFWCollection(self.tree(tmp, ["j714s", "j873g"])).files())
        self.assertEqual(sorted(files), ["apple/centauri/j714s-ftab.bin",
                                         "apple/centauri/j873-ftab.bin"])
        self.assertEqual(files["apple/centauri/j714s-ftab.bin"].sha, PERSONALIZED_SHA256)

    def test_no_n1_inputs_collect_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(centauri.CentauriFWCollection(str(pathlib.Path(tmp) / "x")).files(), [])

    def test_a_model_without_its_ticket_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(centauri.Invalid):
                centauri.CentauriFWCollection(self.tree(tmp, ["j714s"], ticket=False))

    def test_another_models_ticket_is_not_used(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(self.tree(tmp, ["j714s"], ticket=False))
            (root / "j714s" / centauri.ticket_name("j716s")).write_bytes(TICKET)
            with self.assertRaises(centauri.Invalid):
                centauri.CentauriFWCollection(str(root))

    def test_a_directory_that_is_not_a_model_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(centauri.Invalid):
                centauri.CentauriFWCollection(self.tree(tmp, ["..j714s"]))


class Empty:
    def __init__(self, *args, **kwargs):
        pass

    def files(self):
        return []


class UpdateTest(unittest.TestCase):
    def test_a_rebuild_from_all_firmware_keeps_the_n1_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, dest = pathlib.Path(tmp) / "asahi", pathlib.Path(tmp) / "vendorfw"
            source.mkdir()
            dest.mkdir()
            with tarfile.open(source / "all_firmware.tar.gz", "w:gz") as tar:
                for name, data in (("centauri/j714s/" + centauri.IMAGE, IMAGE),
                                   ("centauri/j714s/" + centauri.ticket_name("j714s"), TICKET)):
                    ti = tarfile.TarInfo(name)
                    ti.size = len(data)
                    tar.addfile(ti, io.BytesIO(data))
            others = ("WiFiFWCollection", "BluetoothFWCollection", "MultitouchFWCollection",
                      "ISPFWCollection", "AlsFWCollection", "AudioTuningFWCollection",
                      "KernelFWCollection")
            with contextlib.ExitStack() as stack:
                for name in others:
                    stack.enter_context(mock.patch.object(update, name, Empty))
                update.update_firmware(source, dest)
            manifest = (dest / "manifest.txt").read_text().splitlines()
        self.assertEqual(manifest, [
            f"FILE apple/centauri/j714s-ftab.bin SHA256 {PERSONALIZED_SHA256}"])


if __name__ == "__main__":
    unittest.main()
