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

    @staticmethod
    def _mriya_type(name):
        stem, ext = os.path.splitext(name)
        ext = ext.removeprefix(".")
        if ext == "txt" and (stem == "P-mriya" or stem.startswith("P-mriya-")):
            return ext
        if ext in {"trx", "clmb", "txcb", "sig"} and stem == "mriya":
            return ext
        return None

    @classmethod
    def _complete_mriya(cls, path):
        with os.scandir(path) as entries:
            types = {
                cls._mriya_type(entry.name) for entry in entries
                if entry.is_file() and entry.stat().st_size
            }
        return {"trx", "txt", "clmb", "txcb", "sig"} <= types

    def __init__(self, source_path):
        self.root = FWNode()
        self.load(source_path)
        self.prune()

    def load(self, source_path):
        for dirpath, dirnames, filenames in os.walk(source_path):
            if "perf" in dirnames:
                dirnames.remove("perf")
            if "assert" in dirnames:
                dirnames.remove("assert")
            # The 14.6.1 IPSW has broken C2 data. Only accept a complete
            # Mriya set; continue excluding other C2 firmware families.
            if "C-4388__s-C2" in dirnames:
                if not self._complete_mriya(os.path.join(dirpath, "C-4388__s-C2")):
                    dirnames.remove("C-4388__s-C2")
            subpath = os.path.relpath(dirpath, source_path)
            c2_source = "C-4388__s-C2" in os.path.normpath(dirpath).split(os.sep)
            if c2_source and os.path.basename(dirpath) != "C-4388__s-C2":
                dirnames.clear()
                continue
            for name in sorted(filenames):
                if c2_source and (self._mriya_type(name) is None
                                  or not os.path.isfile(os.path.join(dirpath, name))
                                  or not os.path.getsize(os.path.join(dirpath, name))):
                    continue
                if not any(name.endswith("." + i) for i in self.EXTMAP):
                    continue
                # macOS 14.6/14.8 contains {java,sumatra}_gen* files, possible
                # for generic data. It's not clear how they are used so skip
                # them for now
                if "_gen" in name:
                    continue
                path = os.path.join(dirpath, name)
                relpath = os.path.join(subpath, name)
                if not name.endswith(".txt"):
                    name = "P-" + name
                idpath, ext = os.path.join(subpath, name).rsplit(".", 1)
                props = {}
                for i in idpath.replace("/", "_").split("_"):
                    if not i:
                        continue
                    k, v = i.split("-", 1)
                    if k == "P" and "-" in v:
                        plat, ant = v.split("-", 1)
                        props["P"] = plat
                        props["A"] = ant
                    else:
                        props[k] = v
                ident = [ext]
                for dim in self.DIMS:
                    if dim in props:
                        ident.append(props.pop(dim))
                assert not props

                node = self.root
                for k in ident:
                    node = node.leaves.setdefault(k, FWNode())
                with open(path, "rb") as fd:
                    data = fd.read()

                if name.endswith(".txt"):
                    data = self.process_nvram(data)

                node.this = FWFile(relpath, data)

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
