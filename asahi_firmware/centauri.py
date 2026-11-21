# SPDX-License-Identifier: MIT
"""Apple N1 (Centauri) Wi-Fi and Bluetooth firmware from a stub's restore files.

The same conversion as the native installer's CentauriFirmware
(macOS/Sources/AuroraFirmware/CentauriFirmware.swift). One FTAB image serves
the N1's Wi-Fi and Bluetooth. The restore image ships one image per N1
generation and one ticket per Mac model, and the N1's boot ROM starts an
image only with its model's ticket in it: the ticket is appended to the
image, and the image's header names it (its offset at 0x10 and its size at
0x14, little endian). The installer keeps this Mac's two inputs in
asahi/all_firmware.tar.gz under centauri/<model>/, so a rebuild
(asahi-fwupdate) gives the same file.
"""
import os, re

from .core import FWFile

# Restore-directory paths: the image is the one file the model's build
# identity names for the N1, the ticket is per model.
IMAGE = "ftab.bin"
TICKET_DIR = "centauri"


def ticket_name(model):
    """centauri.<model>ap.im4m: the model's ticket in the restore directory's
    centauri/ (the restore image's Firmware/Manifests/restore/<variant>/)."""
    return f"centauri.{model}ap.im4m"


# The T8152 driver's board table names the J873g's file after the J873; every
# other N1 board's driver requests its model's name (the T6050 device trees'
# firmware-name and the T8142 board table).
KERNEL_MODEL = {"j873g": "j873"}


def firmware_name(model):
    """The file the N1 driver requests on this model."""
    return f"apple/centauri/{KERNEL_MODEL.get(model, model)}-ftab.bin"


MODEL = re.compile(r"[jk][0-9]+[a-z]*")
OWNED = re.compile(r"apple/centauri/[jk][0-9]+[a-z]*-ftab\.bin")

# The driver loads at most 64 MiB.
BUDGET = 64 << 20
TICKET_BUDGET = 1 << 20
MAGIC = b"rkosftab"


class Invalid(ValueError):
    pass


def require(cond, why):
    if not cond:
        raise Invalid(why)


def _der_length(data, at):
    """(length, content offset) of the DER element at at."""
    require(at + 2 <= len(data), "truncated ticket")
    n = data[at + 1]
    if n < 0x80:
        return n, at + 2
    count = n & 0x7f
    require(1 <= count <= 4 and at + 2 + count <= len(data) and data[at + 2] != 0,
            "invalid ticket length")
    length = int.from_bytes(data[at + 2:at + 2 + count], "big")
    require(length >= 0x80, "noncanonical ticket length")
    return length, at + 2 + count


def validate_ticket(data):
    """An IMG4 manifest: one DER SEQUENCE that is the whole file and starts
    with the IA5String IM4M."""
    require(0 < len(data) <= TICKET_BUDGET and data[0] == 0x30, "the ticket is not a manifest")
    length, content = _der_length(data, 0)
    require(content + length == len(data), "the ticket has trailing or missing bytes")
    require(content + 2 <= len(data) and data[content] == 0x16, "the ticket is not a manifest")
    tag, at = _der_length(data, content)
    require(data[at:at + tag] == b"IM4M", "the ticket is not a manifest")


def personalize(image, ticket):
    """The image with ticket appended and named in its header."""
    require(0x30 <= len(image) and len(image) + len(ticket) <= BUDGET,
            "the N1 image is out of bounds")
    require(image[0x20:0x28] == MAGIC, "the N1 image is not an FTAB")
    require(image[0x10:0x18] == bytes(8), "the N1 image already carries a ticket")
    validate_ticket(ticket)
    out = bytearray(image)
    out[0x10:0x14] = len(image).to_bytes(4, "little")
    out[0x14:0x18] = len(ticket).to_bytes(4, "little")
    return bytes(out + ticket)


def _read(path, budget):
    with open(path, "rb") as f:
        data = f.read(budget + 1)
    require(len(data) <= budget, f"{os.path.basename(path)} exceeds its budget")
    return data


class CentauriFWCollection:
    """source_dir: all_firmware's centauri/, one directory per model holding
    IMAGE and its ticket. A missing directory has nothing to collect; a model
    directory without both files, or with files the driver would refuse,
    raises Invalid."""

    def __init__(self, source_dir):
        self.out = {}
        names = sorted(os.listdir(source_dir)) if os.path.isdir(source_dir) else []
        for model in names:
            directory = os.path.join(source_dir, model)
            if not os.path.isdir(directory):
                continue
            require(MODEL.fullmatch(model) is not None, f"{model}: not a Mac model")
            image_path = os.path.join(directory, IMAGE)
            ticket_path = os.path.join(directory, ticket_name(model))
            require(os.path.isfile(image_path), f"{model}: the N1 image is missing")
            require(os.path.isfile(ticket_path), f"{model}: the N1 ticket is missing")
            data = personalize(_read(image_path, BUDGET), _read(ticket_path, TICKET_BUDGET))
            name = firmware_name(model)
            self.out[name] = FWFile(name, data)

    def files(self):
        return sorted(self.out.items())


def owned(name):
    return OWNED.fullmatch(name) is not None
