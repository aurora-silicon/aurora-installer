# SPDX-License-Identifier: MIT
import struct, os, logging
from .img4 import img4p_extract
from .core import FWFile
from .asmedia import extract_asmedia
from . import prores

log = logging.getLogger("asahi_firmware.kernel")

class KernelFWCollection(object):
    def __init__(self, source_path, machine=None):
        self.fwfiles = []
        self.machine = prores.machine() if machine is None else machine
        self.load(source_path)

    def load(self, source_path):
        if os.path.isdir(source_path):
            for fname in os.listdir(source_path):
                if fname.startswith("kernelcache"):
                    kern_path = os.path.join(source_path, fname)
                    break
            else:
                raise Exception("Could not find kernelcache")
        else:
            kern_path = source_path

        log.info(f"Extracting firmware from kernel at {kern_path}")

        with open(kern_path, "rb") as fd:
            im4p = fd.read()
        name, kernel = img4p_extract(im4p)

        for fwf in extract_asmedia(kernel):
            self.fwfiles.append((fwf.name, fwf))

        # The ProRes engine's power-up rows (M4 Pro and M4 Max Macs), from
        # this Mac's own kernel and never shipped. A kernel the reader does
        # not understand leaves ProRes off.
        if self.machine in prores.MACHINES:
            try:
                rows = prores.extract(kernel)
            except prores.ProResError as e:
                log.error(f"ProRes initialization rows not collected: {e}")
            else:
                if rows is None:
                    log.error("ProRes initialization rows not in this kernel")
                else:
                    fwf = FWFile(prores.NAME, rows)
                    self.fwfiles.append((fwf.name, fwf))

    def files(self):
        return self.fwfiles

