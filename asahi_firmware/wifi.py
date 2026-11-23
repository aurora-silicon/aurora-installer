# SPDX-License-Identifier: MIT
import sys, os, os.path, pprint, statistics, logging
from .core import FWFile

log = logging.getLogger("asahi_firmware.wifi")

class FWNode(object):
    def __init__(self, this=None, leaves=None):
        if leaves is None:
            leaves = {}
        self.this = this
        self.leaves = leaves

    def __eq__(self, other):
        return self.this == other.this and self.leaves == other.leaves

    def __hash__(self):
        return hash((self.this, tuple(self.leaves.items())))

    def __repr__(self):
        return f"FWNode({self.this!r}, {self.leaves!r})"

    def print(self, depth=0, tag=""):
        print(f"{'  ' * depth} * {tag}: {self.this or ''} ({hash(self)})")
        for k, v in self.leaves.items():
            v.print(depth + 1, k)

class WiFiFWCollection(object):
    EXTMAP = {
        "trx": "bin",
        "txt": "txt",
        "clmb": "clm_blob",
        "txcb": "txcap_blob",
        "sig": "sig",
    }
    DIMS = ["C", "s", "P", "M", "V", "m", "A"]
    def __init__(self, source_path):
        self.root = FWNode()
        self.load(source_path)
        self.prune()

    def load(self, source_path):
        # macOS names most firmware through aliases (symbolic links, about
        # three per file). Read each file once and let its aliases share the
        # data, or the collection holds every alias's own copy (660 MiB for
        # a 33 MB tree).
        read = {}
        for dirpath, dirnames, filenames in os.walk(source_path):
            if "perf" in dirnames:
                dirnames.remove("perf")
            if "assert" in dirnames:
                dirnames.remove("assert")
            subpath = os.path.relpath(dirpath, source_path)
            for name in sorted(filenames):
                if not any(name.endswith("." + i) for i in self.EXTMAP):
                    continue
                # macOS 14.6/14.8 contains {java,sumatra}_gen* files, possible
                # for generic data. It's not clear how they are used so skip
                # them for now
                if "_gen" in name:
                    continue
                path = os.path.join(dirpath, name)
                relpath = os.path.join(subpath, name)
                # Some Recovery images ship aliases whose target is absent
                # (25G83's C-4388__s-C2/aruba.trx names a missing
                # paradise.trx). Such a link carries no firmware: skip it,
                # like a file the image lacks, and keep the rest of its
                # directory. Anything else that is not a regular file is
                # skipped as well (os.walk lists a socket or FIFO with the
                # files, and opening a FIFO would block).
                if not os.path.isfile(path):
                    if os.path.lexists(path) and not os.path.islink(path):
                        log.warning(f"Skipping firmware name that is not a regular file: {relpath}")
                    else:
                        log.info(f"Skipping dangling firmware alias {relpath}")
                    continue
                if not name.endswith(".txt"):
                    name = "P-" + name
                idpath, ext = os.path.join(subpath, name).rsplit(".", 1)
                # A name this reader cannot place (no key-value parts, an
                # unknown key, no chip or revision) is left out; the rest of
                # the tree is still collected.
                props = self.parse_ident(idpath)
                if props is None:
                    log.warning(f"Skipping firmware file with an unexpected name: {relpath}")
                    continue
                ident = [ext]
                for dim in self.DIMS:
                    if dim in props:
                        ident.append(props.pop(dim))

                st = os.stat(path)
                key = (st.st_dev, st.st_ino, name.endswith(".txt"))
                if key not in read:
                    with open(path, "rb") as fd:
                        data = fd.read()

                    if name.endswith(".txt"):
                        try:
                            data = self.process_nvram(data)
                        except ValueError as e:
                            log.warning(f"Skipping NVRAM file that does not parse: {relpath} ({e})")
                            continue

                    read[key] = FWFile(relpath, data)
                first = read[key]

                node = self.root
                for k in ident:
                    node = node.leaves.setdefault(k, FWNode())
                node.this = FWFile(relpath, first.data, first.sha)

    def parse_ident(self, idpath):
        """{dimension: value} of a firmware path without its extension
        (C-4387__s-C2/P-maui_M-XXXX), or None if it is not of that form."""
        props = {}
        for i in idpath.replace("/", "_").split("_"):
            if not i:
                continue
            k, sep, v = i.partition("-")
            if not sep:
                return None
            if k == "P" and "-" in v:
                plat, ant = v.split("-", 1)
                props["P"] = plat
                props["A"] = ant
            else:
                props[k] = v
        if any(k not in self.DIMS for k in props):
            return None
        # files() names a file by its chip and revision.
        if "C" not in props or "s" not in props:
            return None
        return props

    def prune(self, node=None, depth=0):
        if node is None:
            node = self.root

        for i in node.leaves.values():
            self.prune(i, depth + 1)

        if node.this is None and node.leaves and depth > 3:
            first = next(iter(node.leaves.values()))
            if all(i == first for i in node.leaves.values()):
                node.this = first.this

        for i in node.leaves.values():
            if not i.this or not node.this:
                break
            if i.this != node.this:
                break
        else:
            node.leaves = {}

    def _walk_files(self, node, ident):
        if node.this is not None:
            yield ident, node.this
        for k, subnode in node.leaves.items():
            yield from self._walk_files(subnode, ident + [k])

    def files(self):
        for ident, fwfile in self._walk_files(self.root, []):
            (ext, chip, rev), rest = ident[:3], ident[3:]
            rev = rev.lower()
            ext = self.EXTMAP[ext]

            if rest:
                rest = "," + "-".join(rest)
            else:
                rest = ""
            filename = f"brcm/brcmfmac{chip}{rev}-pcie.apple{rest}.{ext}"

            yield filename, fwfile

    def process_nvram(self, data):
        data = data.decode("ascii")
        keys = {}
        lines = []
        for line in data.split("\n"):
            if not line:
                continue
            key, value = line.split("=", 1)
            keys[key] = value
            # Clean up spurious whitespace that Linux does not like
            lines.append(f"{key.strip()}={value}\n")

        return "".join(lines).encode("ascii")

    def print(self):
        self.root.print()

if __name__ == "__main__":
    col = WiFiFWCollection(sys.argv[1])
    if len(sys.argv) > 2:
        from .core import FWPackage

        pkg = FWPackage(sys.argv[2])
        pkg.add_files(sorted(col.files()))
        pkg.close()

        for i in pkg.manifest:
            print(i)
    else:
        for name, fwfile in col.files():
            if isinstance(fwfile, str):
                print(name, "->", fwfile)
            else:
                print(name, f"({len(fwfile.data)} bytes)")
