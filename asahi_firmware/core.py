# SPDX-License-Identifier: MIT
import tarfile, io, logging, os, os.path, tempfile
from hashlib import sha256
from . import cpio

UBOOT_FILES = set([
    "asmedia/asm2214a-apple.bin"
])

class FWFile(object):
    def __init__(self, name, data, sha=None):
        # sha: data's known SHA-256 (an alias of a file already read).
        self.name = name
        self.data = data
        self.sha = sha or sha256(data).hexdigest()

    def __repr__(self):
        return f"FWFile({self.name!r}, <{self.sha[:16]}>)"

    def __eq__(self, other):
        if other is None:
            return False
        return self.sha == other.sha

    def __hash__(self):
        return hash(self.sha)

class FWPackage(object):
    # The package is built under temporary names beside the final ones and
    # renamed into place by close(), so a run that fails (or never reaches
    # close()) leaves the previous package as it was.
    def __init__(self, path):
        self.closed = True
        self.path = path
        self.tar_path = os.path.join(path, "firmware.tar")
        self.cpio_path = os.path.join(path, "firmware.cpio")
        self.manifest_path = os.path.join(path, "manifest.txt")
        self._staged = {}
        self._uboot = []
        try:
            self.tarfile = tarfile.open(self._stage(self.tar_path), mode="w")
            self.cpiofile = cpio.CPIO(self._stage(self.cpio_path))
        except BaseException:
            self.abort()
            raise
        self.closed = False
        self.hashes = {}
        self.manifest = []

    def _stage(self, final):
        """A new empty file beside final, to be renamed to it on close()."""
        dirname, base = os.path.split(final)
        prefix = f".{base}."
        # A run that was killed leaves its temporary file: drop it, so they
        # do not add up on a small partition.
        for name in os.listdir(dirname or "."):
            if name.startswith(prefix) and name.endswith(".tmp"):
                try:
                    os.unlink(os.path.join(dirname, name))
                except OSError:
                    pass
        fd, tmp = tempfile.mkstemp(prefix=prefix, suffix=".tmp", dir=dirname or ".")
        self._staged[final] = tmp
        # mkstemp's 0600 is for the name; the package keeps the mode a plain
        # open() would have given it.
        umask = os.umask(0)
        os.umask(umask)
        try:
            os.fchmod(fd, 0o666 & ~umask)
        except OSError:
            pass # FAT (the EFI system partition) has no modes to set
        finally:
            os.close(fd)
        return tmp

    def _write_staged(self, final, data):
        with open(self._stage(final), "wb") as fd:
            fd.write(data)

    def _commit(self):
        for tmp in self._staged.values():
            fd = os.open(tmp, os.O_RDONLY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        for final, tmp in list(self._staged.items()):
            os.replace(tmp, final)
            del self._staged[final]

    def abort(self):
        """Drop what was built; the files of an earlier package stay."""
        self.closed = True
        for f in (getattr(self, "tarfile", None), getattr(self, "cpiofile", None)):
            try:
                if f is not None:
                    f.close()
            except Exception:
                pass
        for tmp in self._staged.values():
            try:
                os.unlink(tmp)
            except OSError:
                pass
        self._staged = {}

    def close(self):
        if self.closed:
            return

        try:
            ti = tarfile.TarInfo("vendorfw/.vendorfw.manifest")
            ti.type = tarfile.REGTYPE
            fd = io.BytesIO()
            for i in self.manifest:
                fd.write(i.encode("ascii") + b"\n")
            ti.size = fd.tell()
            fd.seek(0)
            self.cpiofile.addfile(ti, fd)

            self.tarfile.close()
            self.cpiofile.close()

            self._write_staged(self.manifest_path,
                               "".join(i + "\n" for i in self.manifest).encode())
            for path, data in self._uboot:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                self._write_staged(path, data)
            self._commit()
        except BaseException:
            self.abort()
            raise
        self.closed = True

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if exc_type is None:
            self.close()
        else:
            self.abort()

    def add_file(self, name, data, mode=None):
        ti = tarfile.TarInfo(name)
        if name == "apple/audio-tuning/lsm2-param-fill.bin":
            ti.mode = 0o600
        if mode is not None:
            ti.mode = mode
        key = (data.sha, ti.mode)
        fd = None
        if key in self.hashes:
            ti.type = tarfile.LNKTYPE
            ti.linkname = self.hashes[key]
            self.manifest.append(f"LINK {name} {ti.linkname}")
        else:
            ti.type = tarfile.REGTYPE
            ti.size = len(data.data)
            fd = io.BytesIO(data.data)
            self.hashes[key] = name
            self.manifest.append(f"FILE {name} SHA256 {data.sha}")

        logging.info(f"+ {self.manifest[-1]}")
        self.tarfile.addfile(ti, fd)
        if fd is not None:
            fd.seek(0)
        ti.name = os.path.join("vendorfw", ti.name)
        if ti.linkname:
            ti.linkname = os.path.join("vendorfw", ti.linkname)
        self.cpiofile.addfile(ti, fd)

        if name in UBOOT_FILES:
            self._uboot.append((os.path.join(self.path, "u-boot", name), data.data))

    def add_files(self, it):
        for name, data in it:
            self.add_file(name, data)

    def __del__(self):
        # Only close() publishes: a package dropped part-way is discarded.
        if not getattr(self, "closed", True):
            self.abort()
