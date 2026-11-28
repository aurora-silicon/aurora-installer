#!/usr/bin/env python3
"""Regenerate the archives and expected.json for Tests/RestoreImageArchiveCheck.swift.

Every archive is an Apple Encrypted Archive (profile 1) built by aea.py with the disposable
key below. "restore" archives use the restore image's 1 MiB segments and 256 per cluster;
"small" ones 1 KiB segments and 4 per cluster, so a few KiB cover several clusters, a last
cluster with empty slots, and stored and LZFSE segments side by side. Each refusing case is
wrong in one place with every MAC around it right (or, for the MAC cases, one byte changed),
so only the check named in expected.json can catch it. The key is a fixture, nothing else's.
Deterministic. Usage (from this directory; needs pyca/cryptography and Go with
go-compressions/lzfse v0.3.0 in the module cache): python3 generate.py
"""
import hashlib
import json
import os
import random

import aea

KEY = bytes(range(32))
OTHER = bytes(range(1, 33))
SMALL = {"segment": 1024, "width": 4}


def noise(seed, count):
    r = random.Random(seed)
    return bytes(r.getrandbits(8) for _ in range(count))


def text(seed, count):
    r = random.Random(seed)
    words = [b"segment ", b"cluster ", b"archive ", b"recovery ", b"image "]
    out = b""
    while len(out) < count:
        out += r.choice(words)
    return out[:count]


def flip(data, at):
    data = bytearray(data)
    data[at] ^= 0x01
    return bytes(data)


def main():
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    cases = {}

    def write(name, data, plain=None, profile="small", want="ok", key=KEY, lzfse=False):
        with open(name + ".aea", "wb") as out:
            out.write(data)
        # lzfse: decoding needs an LZFSE decoder (a check without one skips the case).
        case = {"profile": profile, "key": key.hex(), "expect": want, "lzfse": lzfse}
        if plain is not None:
            case["bytes"] = len(plain)
            case["sha256"] = hashlib.sha256(plain).hexdigest()
        cases[name] = case

    # The restore image's profile: one stored segment, one LZFSE one, two segments.
    small = noise(1, 3000)
    write("restore-stored", aea.build(small, KEY)[0], small, "restore")
    compressible = text(2, 70000)
    write("restore-lzfse", aea.build(compressible, KEY, compress={0})[0], compressible,
          "restore", lzfse=True)
    two = bytes((1 << 20) - 200) + text(3, 205)
    write("restore-two", aea.build(two, KEY, compress={0})[0], two, "restore", lzfse=True)

    # Ten segments in three clusters (the last has two empty slots), LZFSE every other one.
    # The LZFSE refusals below are caught by the stream walk, before any decoder runs.
    parts = [text(10 + i, 1024) if i % 2 else noise(10 + i, 1024) for i in range(9)]
    plain = b"".join(parts) + text(30, 123)
    lzfse = {1, 3, 5, 7, 9}
    write("clusters", aea.build(plain, KEY, compress=lzfse, **SMALL)[0], plain, lzfse=True)
    # The same image stored: the refusing cases below change it, so that each refusal is
    # reached without an LZFSE decoder.
    base, layout = aea.build(plain, KEY, **SMALL)
    write("clusters-stored", base, plain)
    # Two full clusters, stored; and a one-byte image.
    full = noise(40, 8 * 1024)
    write("full", aea.build(full, KEY, **SMALL)[0], full)
    write("one", aea.build(b"\x5a", KEY, **SMALL)[0], b"\x5a")

    def variant(name, want, **options):
        write(name, aea.build(plain, KEY, **SMALL, **options)[0], None, want=want)

    # One byte changed: each MAC in the chain.
    meta = layout["metadata"]
    write("root-mac", flip(base, layout["root_mac"]), want="authentication")
    write("root-body", flip(base, layout["root"] + 3), want="authentication")
    write("metadata", flip(base, meta + 20), want="authentication")
    write("salt", flip(base, layout["salt"]), want="authentication")
    write("first-cluster-mac", flip(base, layout["root"] + 48), want="authentication")
    cluster = layout["clusters"][1]
    write("cluster-header", flip(base, cluster + 45), want="authentication")
    # The trailer: the next cluster's MAC, then this cluster's segment MACs.
    write("cluster-next-mac", flip(base, cluster + 4 * 40), want="authentication")
    write("cluster-segment-mac", flip(base, cluster + 4 * 40 + 32 + 2 * 32 + 5),
          want="authentication")
    write("segment-body", flip(base, layout["clusters"][2] - 7), want="authentication")
    write("last-segment-body", flip(base, len(base) - 1), want="authentication")
    write("wrong-key", base, want="authentication", key=OTHER)

    # Every MAC right, one field wrong.
    def digest(segs):
        segs[4]["digest"] = bytes(32)
    variant("segment-digest", "segmentDigest", segments_hook=digest)

    def short_stream(segs):
        # An LZFSE body that decodes to one byte less than the header says.
        body = aea.lzfse(parts[3][:-1])
        segs[3].update(body=body, size=len(body))
    variant("lzfse-short", "segmentDigest", segments_hook=short_stream)

    def trailing_stream(segs):
        body = aea.lzfse(parts[5]) + b"junk"
        segs[5].update(body=body, size=len(body))
    variant("lzfse-trailing", "segmentDigest", segments_hook=trailing_stream)

    def wrong_plain(segs):
        segs[2]["psize"] = 1023
    variant("plain-size", "invalidArchive", segments_hook=wrong_plain)

    def over(segs):
        body = parts[6] + b"x"
        segs[6].update(body=body, size=len(body))
    variant("size-over-plain", "invalidArchive", segments_hook=over)

    def empty_body(segs):
        segs[0].update(body=b"", size=0)
    variant("size-zero", "invalidArchive", segments_hook=empty_body)

    def tail_slot(segs):
        segs[10].update(psize=1, size=1, body=b"x", digest=hashlib.sha256(b"x").digest())
    variant("extra-segment", "invalidArchive", segments_hook=tail_slot)

    def field(key, value):
        return lambda fields: fields.__setitem__(key, value)
    variant("root-archive-size", "invalidArchive", root_hook=field("total", len(base) + 1))
    variant("root-plain-size", "invalidArchive", root_hook=field("plain", len(plain) + 1))
    variant("root-plain-zero", "invalidArchive", root_hook=field("plain", 0))
    variant("root-segment", "invalidArchive", root_hook=field("segment", 2048))
    variant("root-width", "invalidArchive", root_hook=field("width", 8))
    variant("root-codec", "invalidArchive", root_hook=field("codec", b"z"))
    variant("root-digest", "invalidArchive", root_hook=field("digest", 1))
    # Lengths: the archive ends before its last segment does. Padding after it, within
    # the length the root names, is dropped (Apple's Recovery images have some).
    variant("truncated", "invalidArchive", cut=10)
    write("padded", aea.build(plain, KEY, **SMALL, extra=noise(50, 3000))[0], plain)
    # Header: another profile, and metadata that runs past the prefix.
    write("profile", base[:4] + b"\x02" + base[5:], want="invalidArchive")
    write("metadata-length", base[:8] + (1 << 20 | 1).to_bytes(4, "little") + base[12:],
          want="invalidArchive")

    with open("expected.json", "w") as out:
        json.dump(cases, out, indent=1, sort_keys=True)
        out.write("\n")


if __name__ == "__main__":
    main()
