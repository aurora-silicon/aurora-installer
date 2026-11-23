# SPDX-License-Identifier: MIT
import pathlib, sys, tempfile, os.path

from .archive import extract_archive

from .core import FWPackage, FWPackageBusy
from .wifi import WiFiFWCollection
from .bluetooth import BluetoothFWCollection
from .multitouch import MultitouchFWCollection
from .kernel import KernelFWCollection
from .isp import ISPFWCollection
from .als import AlsFWCollection
from .audio_tuning import AudioTuningFWCollection

def collect_firmware(source, raw_fw, pkg):
    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = pathlib.Path(tmpdir)
        extract_archive(raw_fw, tmpdir)

        col = WiFiFWCollection(str(tmpdir.joinpath("firmware", "wifi")))
        pkg.add_files(sorted(col.files()))

        col = BluetoothFWCollection(str(tmpdir.joinpath("firmware", "bluetooth")))
        pkg.add_files(sorted(col.files()))

        col = MultitouchFWCollection(str(tmpdir.joinpath("fud_firmware")))
        pkg.add_files(sorted(col.files()))

        col = ISPFWCollection(str(tmpdir))
        pkg.add_files(sorted(col.files()))

        col = AlsFWCollection(str(tmpdir))
        pkg.add_files(sorted(col.files()))

        col = AudioTuningFWCollection(str(tmpdir))
        pkg.add_files(sorted(col.files()))

    col = KernelFWCollection(str(source))
    pkg.add_files(sorted(col.files()))

def update_firmware(source, dest):
    # Look at the source before anything is created in dest, and publish the
    # package only when all of it was built (FWPackage renames on close):
    # a run that fails leaves the package dest already holds.
    raw_fw = source.joinpath("all_firmware.tar.gz")
    if not raw_fw.is_file():
        raise FileNotFoundError(f"Could not find {raw_fw}")

    with FWPackage(dest) as pkg:
        collect_firmware(source, raw_fw, pkg)

def main():
    import argparse
    import logging
    logging.basicConfig()

    parser = argparse.ArgumentParser(description='Update vendor firmware tarball')
    parser.add_argument('source', metavar='SOURCE', type=pathlib.Path,
                        help='path containing raw firmware')
    parser.add_argument('dest', metavar='DEST', type=pathlib.Path,
                        help='output path for vendor firmware')
    
    args = parser.parse_args()

    try:
        update_firmware(args.source, args.dest)
    except (FileNotFoundError, FWPackageBusy) as e:
        print(f"asahi-fwextract: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
