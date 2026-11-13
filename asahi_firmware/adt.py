# SPDX-License-Identifier: MIT
"""A read-only reader of the Apple device tree (ADT), as iBoot hands it to
the boot chain and aura exposes it to Linux (the "adt" MTD partition).

The format: a node is `u32 property count, u32 child count`, its properties,
then its children. A property is a 32-byte NUL-padded name, a `u32` size
(bit 31 marks a template), and the value padded to 4 bytes. Only reading is
supported; values are returned as bytes.
"""
import struct

MAX_DEPTH = 64
NAME_BYTES = 32
TEMPLATE = 0x80000000


class AdtError(ValueError):
    pass


class Node(object):
    def __init__(self, properties, children):
        self.properties = properties
        self.children = children

    @property
    def name(self):
        raw = self.properties.get("name", b"")
        return raw.rstrip(b"\0").decode("ascii", "replace")

    def get(self, prop, default=None):
        return self.properties.get(prop, default)

    def child(self, name):
        found = [c for c in self.children if c.name == name]
        return found[0] if len(found) == 1 else None

    def find(self, path):
        """The node at a /-separated path from this one, or None."""
        node = self
        for part in [p for p in path.split("/") if p]:
            node = node.child(part)
            if node is None:
                return None
        return node

    def walk(self):
        yield self
        for c in self.children:
            yield from c.walk()


def _node(data, off, depth):
    if depth > MAX_DEPTH:
        raise AdtError("ADT nested too deeply")
    if off + 8 > len(data):
        raise AdtError("truncated ADT node")
    nprops, nchildren = struct.unpack_from("<II", data, off)
    off += 8
    props = {}
    for _ in range(nprops):
        if off + NAME_BYTES + 4 > len(data):
            raise AdtError("truncated ADT property")
        name = bytes(data[off:off + NAME_BYTES]).split(b"\0", 1)[0].decode("ascii", "replace")
        (size,) = struct.unpack_from("<I", data, off + NAME_BYTES)
        size &= ~TEMPLATE
        off += NAME_BYTES + 4
        if off + size > len(data):
            raise AdtError(f"ADT property {name!r} runs past the end")
        props[name] = bytes(data[off:off + size])
        off += (size + 3) & ~3
    children = []
    for _ in range(nchildren):
        child, off = _node(data, off, depth + 1)
        children.append(child)
    return Node(props, children), off


def parse(data):
    """The root node of an ADT blob. Trailing bytes (an MTD partition is
    larger than the tree) are ignored."""
    root, _ = _node(memoryview(data), 0, 0)
    return root
