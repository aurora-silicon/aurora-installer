# SPDX-License-Identifier: MIT
import pathlib, tempfile, subprocess, os.path

from .core import FWPackage
from .wifi import WiFiFWCollection
from .bluetooth import BluetoothFWCollection
from .multitouch import MultitouchFWCollection
from .kernel import KernelFWCollection
from .isp import ISPFWCollection
from .als import AlsFWCollection
from .avd import AVDFWCollection, collect_from_restore, selected_chip_id, selected_identity

def update_firmware(source, dest):
    chip_id = selected_chip_id(source)
    identity = selected_identity(source)
    avd = collect_from_restore(source, identity, chip_id) if identity is not None else None
    raw_fw = source.joinpath("all_firmware.tar.gz")
    if not raw_fw.exists():
        print(f"Could not find {raw_fw}")
    
    pkg = FWPackage(dest)

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = pathlib.Path(tmpdir)
        subprocess.run(["tar", "xf", str(raw_fw.resolve())], cwd=tmpdir, check=True)

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

        if avd is None:
            col = AVDFWCollection(tmpdir, chip_id)
            pkg.add_files(sorted(col.files()))
        else:
            pkg.add_file(avd.name, avd)

    col = KernelFWCollection(str(source))
    pkg.add_files(sorted(col.files()))

    pkg.close()

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

    update_firmware(args.source, args.dest)

if __name__ == "__main__":
    main()
