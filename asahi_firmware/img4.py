# SPDX-License-Identifier: MIT
import sys
try:
    from . import asn1
except ImportError:
    import asn1
from ctypes import *

__all__ = ["img4p_extract_compressed", "img4p_extract", "IM4PError",
           "MAX_RAW_SIZE"]

# The payloads read here are a macOS kernelcache (120 MiB uncompressed, 32 MiB
# compressed, for a 2024 MacBook Pro) and the multitouch firmware plist. The
# uncompressed size comes from the file and sizes the output buffer, so it is
# bounded, with room for kernels to grow.
MAX_RAW_SIZE = 512 << 20

class IM4PError(ValueError):
    """Not an IM4P this reader understands."""

def check_raw_size(raw_size):
    # A compressed payload holds at least one byte: nothing compresses an
    # empty one (the reference lzfse encoder cannot even produce it), and a
    # size of 0 would accept any compressed data without decoding a byte.
    if not isinstance(raw_size, int) or isinstance(raw_size, bool) \
            or not 1 <= raw_size <= MAX_RAW_SIZE:
        raise IM4PError(f"IM4P uncompressed size {raw_size!r} is not in 1..{MAX_RAW_SIZE}")

def check_decoded(dest, decoded, raw_size):
    """lzfse_decode_buffer and compression_decode_buffer stop at dst_size
    and return it, also when the stream holds more. The buffer is one byte
    larger than raw_size, so a stream that decodes to more than raw_size
    fills it and is refused rather than cut to the expected size."""
    if decoded != raw_size:
        more = " or more" if decoded > raw_size else ""
        raise IM4PError(f"IM4P payload decompressed to {decoded}{more} bytes, not {raw_size}")
    return dest.raw[:raw_size]

def decode_lzfse_liblzfse(cdata, raw_size):
    check_raw_size(raw_size)
    try:
        lzfse = CDLL("liblzfse.so.1")
    except OSError:
        lzfse = CDLL("liblzfse.so")

    # size_t lzfse_decode_buffer(uint8_t *dst, size_t dst_size,
    #     const uint8_t *src, size_t src_size, void *scratch);
    decode = lzfse.lzfse_decode_buffer
    decode.argtypes = [c_char_p, c_size_t, c_char_p, c_size_t, c_void_p]
    decode.restype = c_size_t

    cdata = bytes(cdata)
    dest = create_string_buffer(raw_size + 1)
    decoded = decode(dest, raw_size + 1, cdata, len(cdata), None)
    return check_decoded(dest, decoded, raw_size)

def decode_lzfse_darwin(cdata, raw_size):
    check_raw_size(raw_size)
    compression = CDLL("libcompression.dylib")

    # size_t compression_decode_buffer(uint8_t *dst, size_t dst_size,
    #     const uint8_t *src, size_t src_size, void *scratch, int algorithm);
    decode = compression.compression_decode_buffer
    decode.argtypes = [c_char_p, c_size_t, c_char_p, c_size_t, c_void_p, c_int]
    decode.restype = c_size_t

    cdata = bytes(cdata)
    dest = create_string_buffer(raw_size + 1)
    COMPRESSION_LZFSE = 0x801
    decoded = decode(dest, raw_size + 1, cdata, len(cdata), None, COMPRESSION_LZFSE)
    return check_decoded(dest, decoded, raw_size)

if sys.platform == 'darwin':
    decode_lzfse = decode_lzfse_darwin
else:
    decode_lzfse = decode_lzfse_liblzfse

IA5STRING = asn1.Tag(asn1.Numbers.IA5String, asn1.Types.Primitive, 0)
OCTETSTRING = asn1.Tag(asn1.Numbers.OctetString, asn1.Types.Primitive, 0)
INTEGER = asn1.Tag(asn1.Numbers.Integer, asn1.Types.Primitive, 0)

def enter_sequence(decoder, what):
    tag = decoder.peek()
    if tag is None or tag.nr != asn1.Numbers.Sequence or tag.typ != asn1.Types.Constructed:
        raise IM4PError(f"IM4P {what} is not a sequence")
    decoder.enter()

def read_field(decoder, expected, what):
    if decoder.peek() is None:
        raise IM4PError(f"IM4P {what} is missing")
    tag, value = decoder.read()
    if tag != expected:
        raise IM4PError(f"IM4P {what} has the wrong type")
    return value

def decode_header(decoder):
    enter_sequence(decoder, "container")

    if read_field(decoder, IA5STRING, "magic") != "IM4P":
        raise IM4PError("IM4P magic not found")

    name = read_field(decoder, IA5STRING, "type")
    unk = read_field(decoder, IA5STRING, "description")
    data = read_field(decoder, OCTETSTRING, "payload")

    return name, data

def img4p_extract(data):
    try:
        decoder = asn1.Decoder()
        decoder.start(data)
        name, cdata = decode_header(decoder)

        tag = decoder.peek()
        if tag is None:
            return name, cdata

        enter_sequence(decoder, "compression info")

        if read_field(decoder, INTEGER, "compression type") != 1:
            raise IM4PError("IM4P compression type is not LZFSE")

        raw_size = read_field(decoder, INTEGER, "uncompressed size")
        check_raw_size(raw_size)
    except asn1.Error as e:
        raise IM4PError(f"IM4P is not valid DER: {e}") from e

    return name, decode_lzfse(cdata, raw_size)

if __name__ == "__main__":
    import sys

    data = open(sys.argv[1], "rb").read()
    name, raw = img4p_extract(data)
    with open(sys.argv[2], "wb") as fd:
        fd.write(raw)
