# SPDX-License-Identifier: MIT
"""The T6041 ProRes engine's power-up rows, read from this Mac's own kernel.

The Linux driver (`apple,t6041-prores`) programs three blocks of
read-modify-write rows every time the engine powers up: SCODEC-system,
ProRes core and the SCODEC AXI-to-fabric wrapper. They live in macOS's
AppleProResHW kext, so they are rebuilt from the kernel cache of the Mac
itself into `apple/prores-t6041-init.bin` and never shipped.

The tables are found through the kext's own symbols, with no address,
offset, hash or value compiled in:

1. In the `com.apple.driver.AppleProResHW` fileset entry (or a thin kext
   image), each block family has `tunableh_<family>_figs_<n>.figs` tables and
   `tunableh_<family>_figs_<n>_apply_to` selectors. The selector for this
   engine materialises the SoC number 0x6041 (MOVZ) and takes the address of
   a table of its family (ADRP + ADD).
2. A table is a run of 32-bit pointers, relative to the kernel collection,
   to `fig` entries whose symbol names carry the register offset, width,
   mask, value and getter. The collection base is inferred by matching the
   whole run against those symbols.
3. Each block must decode to exactly one table of exactly the count the
   driver expects, ending where the count ends, with 32-bit entries, a null
   getter, aligned and unique offsets inside the block's window, nonzero
   masks and values inside their masks.

A kernel without the kext or without a T6041 selector yields None. One with
a selector but missing, damaged or duplicate tables raises ProResError, with
no fallback table. Errors never carry offsets, masks or values. The native
installer applies the same rule (macOS/Sources/AuroraFirmware/
ProResInitFirmware.swift).
"""
import re
import struct

NAME = "apple/prores-t6041-init.bin"
# The M4 Pro and M4 Max Macs. Kernel caches for other Macs carry the T6041
# tables too, so the rows are collected for these machines only.
MACHINES = frozenset({"j614s", "j616s", "j773s", "j614c", "j616c", "j575c"})
FILESET_ENTRY = "com.apple.driver.AppleProResHW"
SOC = 0x6041
MAX_FUNCTION_BYTES = 0x4000

# (block id, label, family, count, offset limit), in APRI v1 order.
BLOCKS = (
    (1, "SCODEC-system", "scodec_sys", 82, 0x4000),
    (2, "ProRes core", "prores", 80, 0x4000),
    (3, "SCODEC wrapper", "af_scodecaxi2af", 62, 0x1000000),
)

FIG = re.compile(r"_?fig_([0-9a-fA-F]+)_([0-9]+)_([0-9a-fA-F]+)_([0-9a-fA-F]+)_([A-Za-z0-9_]+)")


class ProResError(Exception):
    """An extraction failure, safe to print."""


def _u32(data, offset):
    if offset < 0 or offset + 4 > len(data):
        raise ProResError("malformed AppleProResHW image: truncated structure")
    return struct.unpack_from("<I", data, offset)[0]


def _u64(data, offset):
    return _u32(data, offset) | _u32(data, offset + 4) << 32


def _string(data, offset, end):
    if offset < 0 or offset >= end or end > len(data):
        raise ProResError("malformed AppleProResHW image: invalid string")
    stop = data.find(b"\0", offset, end)
    if stop < 0:
        raise ProResError("malformed AppleProResHW image: invalid string")
    try:
        return data[offset:stop].decode("utf-8")
    except UnicodeDecodeError:
        raise ProResError("malformed AppleProResHW image: invalid string") from None


def _matches(name, family, suffix):
    pattern = r"_?tunableh_" + re.escape(family) + r"_figs_[0-9]+" + re.escape(suffix)
    return re.fullmatch(pattern, name) is not None


class _Image:
    def __init__(self, data, header=0, bias=0):
        self.data = data
        self.sections = []  # (index, address, size, file offset)
        self.symbols = []  # (name, value, section)
        self.fileset = []  # (name, header offset)
        if _u32(data, header) != 0xFEEDFACF:
            raise ProResError("malformed AppleProResHW image: not a little-endian 64-bit Mach-O")
        self.filetype = _u32(data, header + 12)
        ncmds = _u32(data, header + 16)
        end = header + 32 + _u32(data, header + 20)
        if end > len(data):
            raise ProResError("malformed AppleProResHW image: truncated load commands")
        command = header + 32
        symtab = None
        for _ in range(ncmds):
            if command + 8 > end:
                raise ProResError("malformed AppleProResHW image: truncated load command")
            cmd, size = struct.unpack_from("<II", data, command)
            if size < 8 or command + size > end:
                raise ProResError("malformed AppleProResHW image: invalid load command size")
            if cmd == 0x19:  # LC_SEGMENT_64
                count = _u32(data, command + 64) if size >= 72 else -1
                if count < 0 or 72 + count * 80 > size:
                    raise ProResError("malformed AppleProResHW image: short section table")
                for number in range(count):
                    entry = command + 72 + number * 80
                    self.sections.append((len(self.sections) + 1, _u64(data, entry + 32),
                                          _u64(data, entry + 40), bias + _u32(data, entry + 48)))
            elif cmd == 0x2:  # LC_SYMTAB
                if size < 24:
                    raise ProResError("malformed AppleProResHW image: short symbol table command")
                symtab = struct.unpack_from("<IIII", data, command + 8)
            elif cmd == 0x80000035:  # LC_FILESET_ENTRY
                if size < 32:
                    raise ProResError("malformed AppleProResHW image: short fileset entry")
                offset = _u64(data, command + 16)
                if offset >= len(data):
                    raise ProResError("malformed AppleProResHW image: fileset entry outside input")
                name = _string(data, command + _u32(data, command + 24), command + size)
                self.fileset.append((name, offset))
            command += size
        if symtab is not None:
            symoff, nsyms, stroff, strsize = symtab
            symoff += bias
            stroff += bias
            if symoff < 0 or symoff + nsyms * 16 > len(data):
                raise ProResError("malformed AppleProResHW image: symbol table outside the input")
            if stroff < 0 or stroff + strsize > len(data):
                raise ProResError("malformed AppleProResHW image: string table outside the input")
            for index in range(nsyms):
                strx, n_type, n_sect, _desc, value = struct.unpack_from(
                    "<IBBHQ", data, symoff + index * 16)
                # Skip debugger (stab) entries and unnamed symbols.
                if strx == 0 or strx >= strsize or n_type & 0xE0:
                    continue
                self.symbols.append((_string(data, stroff + strx, stroff + strsize), value, n_sect))

    def file_offset(self, address, size):
        for _index, start, length, offset in self.sections:
            if start <= address and address + size <= start + length:
                position = offset + address - start
                return position if 0 <= position <= len(self.data) - size else None
        return None

    def end(self, value, section):
        later = [v for _n, v, s in self.symbols if s == section and v > value]
        if later:
            return min(later)
        for index, start, length, _offset in self.sections:
            if index == section:
                return start + length
        return None

    def figs(self):
        result, ambiguous = {}, set()
        for name, value, _section in self.symbols:
            match = FIG.fullmatch(name)
            if not match:
                continue
            offset, _width, mask, fig_value, getter = match.groups()
            item = (int(offset, 16), int(mask, 16), int(fig_value, 16), getter)
            if value in result and result[value] != item:
                ambiguous.add(value)
            else:
                result[value] = item
        for value in ambiguous:
            result.pop(value, None)
        return result


def _appleproreshw(data):
    root = _Image(data)
    entries = [offset for name, offset in root.fileset if name == FILESET_ENTRY]
    if root.filetype != 0xC and not entries:
        if any(_matches(name, "prores", "_apply_to") for name, _v, _s in root.symbols):
            return root
        return None
    if not entries:
        return None
    if len(entries) != 1:
        raise ProResError(f"malformed AppleProResHW image: {len(entries)} AppleProResHW entries")
    # Fileset entries keep either collection-wide or entry-relative offsets.
    choices = []
    for bias in (0, entries[0]):
        try:
            image = _Image(data, entries[0], bias)
        except ProResError:
            continue
        if any(_matches(name, "prores", ".figs") for name, _v, _s in image.symbols):
            choices.append(image)
    if len(choices) != 1:
        raise ProResError("malformed AppleProResHW image: unresolved AppleProResHW entry")
    return choices[0]


def _movz(code, immediate):
    for position in range(0, len(code) - 3, 4):
        instruction = struct.unpack_from("<I", code, position)[0]
        if instruction & 0x7F800000 != 0x52800000:
            continue
        shift = (instruction >> 21) & 3
        if ((instruction >> 5) & 0xFFFF) << (shift * 16) == immediate:
            return True
    return False


def _references(code, address):
    result = set()
    for position in range(0, len(code) - 7, 4):
        first, second = struct.unpack_from("<II", code, position)
        if first & 0x9F000000 != 0x90000000 or second & 0x7F000000 != 0x11000000:
            continue
        if (second >> 5) & 0x1F != first & 0x1F:
            continue
        raw = ((first >> 5) & 0x7FFFF) << 2 | (first >> 29) & 3
        pages = (raw ^ 0x100000) - 0x100000
        immediate = (second >> 10) & 0xFFF
        if second & (1 << 22):
            immediate <<= 12
        pc = address + position
        result.add(((pc & ~0xFFF) + (pages << 12) + immediate) & 0xFFFFFFFFFFFFFFFF)
    return result


def _decode(image, address, block, figs):
    _id, _label, _family, count, limit = block
    start = image.file_offset(address, (count + 1) * 8)
    if start is None:
        return None
    # Collection-relative pointers: the low 32 bits of each 64-bit slot.
    pointers = [_u32(image.data, start + index * 8) for index in range(count + 1)]
    decoded = set()
    for fig in figs:
        base = fig - pointers[0]
        if base + pointers[count] in figs:
            continue
        rows, offsets = [], set()
        for pointer in pointers[:count]:
            item = figs.get(base + pointer)
            if item is None:
                break
            offset, mask, value, getter = item
            if (getter != "null" or offset & 3 or offset >= limit or not mask
                    or mask > 0xFFFFFFFF or value & ~mask or offset in offsets):
                break
            offsets.add(offset)
            rows.append((offset, mask, value))
        if len(rows) == count:
            decoded.add(tuple(rows))
    return decoded.pop() if len(decoded) == 1 else None


def _candidates(image, block, figs):
    _id, _label, family, _count, _limit = block
    tables = {value for name, value, _s in image.symbols if _matches(name, family, ".figs")}
    selectors, found = 0, {}
    for name, value, section in image.symbols:
        if not _matches(name, family, "_apply_to"):
            continue
        end = image.end(value, section)
        if end is None or end <= value or end - value > MAX_FUNCTION_BYTES:
            continue
        start = image.file_offset(value, end - value)
        if start is None:
            continue
        code = image.data[start:start + end - value]
        if not _movz(code, SOC):
            continue
        selectors += 1
        for address in _references(code, value):
            if address in tables and address not in found:
                rows = _decode(image, address, block, figs)
                if rows is not None:
                    found[address] = rows
    return selectors, list(found.values())


def extract(kernel):
    """The APRI container for `kernel` (an unwrapped kernel collection or a
    thin AppleProResHW image), or None when it has no T6041 ProRes engine."""
    image = _appleproreshw(kernel)
    if image is None:
        return None
    figs = image.figs()
    selected, selectors = [], 0
    for block in BLOCKS:
        found, tables = _candidates(image, block, figs)
        selectors += found
        if found and len(tables) != 1:
            raise ProResError(f"{block[1]}: expected one T6041 table, found {len(tables)}")
        selected.extend(tables[:1])
    if not selectors:
        return None
    if len(selected) != len(BLOCKS):
        raise ProResError(f"malformed AppleProResHW image: "
                          f"{len(BLOCKS) - len(selected)} T6041 block(s) without a selector")
    out = bytearray(struct.pack("<4sIII", b"APRI", 1, SOC, len(BLOCKS)))
    for (block_id, _label, _family, _count, _limit), rows in zip(BLOCKS, selected):
        out += struct.pack("<II", block_id, len(rows))
        for row in rows:
            out += struct.pack("<III", *row)
    return bytes(out)


def machine():
    """This Mac's board name (`j616s`) from the device tree, or None."""
    try:
        with open("/proc/device-tree/compatible", "rb") as fd:
            first = fd.read(256).split(b"\0", 1)[0].decode("ascii", "replace")
    except OSError:
        return None
    return first[len("apple,"):] if first.startswith("apple,") else None
