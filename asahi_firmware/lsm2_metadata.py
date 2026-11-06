# SPDX-License-Identifier: MIT
"""Collect public lsm2 AudioUnit parameter metadata without rendering.

The component is instantiated only long enough to enumerate its global
parameter list and read ``AudioUnitParameterInfo``. It is never initialized,
rendered, or connected to an audio device.
"""
import ctypes
import json
import math


class MetadataError(ValueError):
    pass


KIND = "aurora-lsm2-parameter-metadata"
VERSION = 1
NAME = "lsm2-metadata.json"
PARAMETER_NAMES = ("VelocityLimit0", "VelocityLimit1", "VelocityLimit2")
COMPONENT = "/System/Library/Components/AudioDSP.component/Contents/MacOS/AudioDSP"
_component_image = None


def velocity_parameter_max(records):
    """Validate ``(name, maximum)`` records and return their shared maximum.

    Every VelocityLimit member must occur, every member must have the same
    number of families, and every published maximum must be identical,
    finite and positive. Unrelated AudioUnit parameters are ignored.
    """
    found = {name: [] for name in PARAMETER_NAMES}
    for name, maximum in records:
        if name in found:
            if not isinstance(maximum, (int, float)) or not math.isfinite(maximum) or maximum <= 0:
                raise MetadataError(f"{name} has an invalid maximum")
            found[name].append(float(maximum))
    counts = {len(values) for values in found.values()}
    if counts == {0} or len(counts) != 1 or 0 in counts:
        raise MetadataError("VelocityLimit parameter families are missing or inconsistent")
    values = [value for maxima in found.values() for value in maxima]
    if any(value != values[0] for value in values[1:]):
        raise MetadataError("VelocityLimit parameter maxima are inconsistent")
    return values[0]


def encode(maximum):
    maximum = velocity_parameter_max((name, maximum) for name in PARAMETER_NAMES)
    return (json.dumps({
        "kind": KIND,
        "version": VERSION,
        "velocity_parameter_max": maximum,
    }, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def decode(data):
    try:
        value = json.loads(data)
    except (TypeError, ValueError) as error:
        raise MetadataError(f"malformed lsm2 metadata: {error}") from error
    if not isinstance(value, dict) or set(value) != {"kind", "version", "velocity_parameter_max"} \
            or value["kind"] != KIND or value["version"] != VERSION:
        raise MetadataError("unknown lsm2 metadata record")
    return velocity_parameter_max((name, value["velocity_parameter_max"])
                                  for name in PARAMETER_NAMES)


def _fourcc(value):
    return int.from_bytes(value.encode("ascii"), "big")


class _Description(ctypes.Structure):
    _fields_ = [("componentType", ctypes.c_uint32),
                ("componentSubType", ctypes.c_uint32),
                ("componentManufacturer", ctypes.c_uint32),
                ("componentFlags", ctypes.c_uint32),
                ("componentFlagsMask", ctypes.c_uint32)]


class _ParameterInfo(ctypes.Structure):
    _fields_ = [("name", ctypes.c_char * 52),
                ("unitName", ctypes.c_void_p),
                ("clumpID", ctypes.c_uint32),
                ("cfNameString", ctypes.c_void_p),
                ("unit", ctypes.c_uint32),
                ("minValue", ctypes.c_float),
                ("maxValue", ctypes.c_float),
                ("defaultValue", ctypes.c_float),
                ("flags", ctypes.c_uint32)]


def read(component_path=COMPONENT):
    """Read the shared VelocityLimit maximum through public AudioUnit APIs."""
    global _component_image
    try:
        audio = ctypes.CDLL(
            "/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")
        core = ctypes.CDLL(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        # Keep the image loaded: AudioComponentRegister retains its factory
        # pointer for the lifetime of this process.
        _component_image = ctypes.CDLL(component_path)
    except OSError as error:
        raise MetadataError(f"cannot load lsm2 AudioUnit: {error}") from error

    audio.AudioComponentFindNext.argtypes = [ctypes.c_void_p, ctypes.POINTER(_Description)]
    audio.AudioComponentFindNext.restype = ctypes.c_void_p
    audio.AudioComponentRegister.argtypes = [ctypes.POINTER(_Description), ctypes.c_void_p,
                                              ctypes.c_uint32, ctypes.c_void_p]
    audio.AudioComponentRegister.restype = ctypes.c_void_p
    audio.AudioComponentInstanceNew.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
    audio.AudioComponentInstanceNew.restype = ctypes.c_int32
    audio.AudioComponentInstanceDispose.argtypes = [ctypes.c_void_p]
    audio.AudioComponentInstanceDispose.restype = ctypes.c_int32
    audio.AudioUnitGetPropertyInfo.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32,
                                               ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32),
                                               ctypes.c_void_p]
    audio.AudioUnitGetPropertyInfo.restype = ctypes.c_int32
    audio.AudioUnitGetProperty.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32,
                                           ctypes.c_uint32, ctypes.c_void_p,
                                           ctypes.POINTER(ctypes.c_uint32)]
    audio.AudioUnitGetProperty.restype = ctypes.c_int32
    core.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
    core.CFStringCreateWithCString.restype = ctypes.c_void_p
    core.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long,
                                        ctypes.c_uint32]
    core.CFStringGetCString.restype = ctypes.c_bool
    core.CFRelease.argtypes = [ctypes.c_void_p]

    description = _Description(_fourcc("aufx"), _fourcc("lsm2"), _fourcc("appl"), 0, 0)
    component = audio.AudioComponentFindNext(None, ctypes.byref(description))
    if not component:
        try:
            factory = ctypes.cast(getattr(_component_image, "AULoudspeakerManagerV2Factory"), ctypes.c_void_p)
        except AttributeError as error:
            raise MetadataError("lsm2 AudioUnit factory is absent") from error
        name = core.CFStringCreateWithCString(None, b"Aurora tuning metadata", 0x08000100)
        if not name:
            raise MetadataError("cannot create AudioUnit registration name")
        try:
            component = audio.AudioComponentRegister(ctypes.byref(description), name, 0x10001, factory)
        finally:
            core.CFRelease(name)
    if not component:
        raise MetadataError("cannot register lsm2 AudioUnit")

    unit = ctypes.c_void_p()
    status = audio.AudioComponentInstanceNew(component, ctypes.byref(unit))
    if status or not unit:
        raise MetadataError(f"cannot instantiate lsm2 AudioUnit ({status})")
    try:
        size = ctypes.c_uint32()
        status = audio.AudioUnitGetPropertyInfo(unit, 3, 0, 0, ctypes.byref(size), None)
        if status or size.value == 0 or size.value % ctypes.sizeof(ctypes.c_uint32):
            raise MetadataError(f"cannot read lsm2 parameter list size ({status})")
        count = size.value // ctypes.sizeof(ctypes.c_uint32)
        identifiers = (ctypes.c_uint32 * count)()
        if audio.AudioUnitGetProperty(unit, 3, 0, 0, identifiers, ctypes.byref(size)):
            raise MetadataError("cannot read lsm2 parameter list")
        records = []
        for identifier in identifiers:
            info = _ParameterInfo()
            info_size = ctypes.c_uint32(ctypes.sizeof(info))
            if audio.AudioUnitGetProperty(unit, 4, 0, identifier,
                                          ctypes.byref(info), ctypes.byref(info_size)):
                raise MetadataError(f"cannot read lsm2 parameter metadata for {identifier}")
            name = bytes(info.name).split(b"\0", 1)[0].decode("utf-8", "replace")
            if info.cfNameString:
                buffer = ctypes.create_string_buffer(256)
                if core.CFStringGetCString(info.cfNameString, buffer, len(buffer), 0x08000100):
                    name = buffer.value.decode("utf-8", "strict")
                if info.flags & (1 << 4):
                    core.CFRelease(info.cfNameString)
            records.append((name, float(info.maxValue)))
        return velocity_parameter_max(records)
    finally:
        audio.AudioComponentInstanceDispose(unit)
