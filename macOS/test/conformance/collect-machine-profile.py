#!/usr/bin/env python3
"""Read-only machine profile collector for the installer conformance harness.

Runs on the target Mac under Linux as root. It never writes to any block
device: every device is opened O_RDONLY and only read with os.pread. It prints
one JSON document with the facts the native installer's inspection consumes:
board, chip, boot firmware versions, the internal GPT, and for each APFS
container its capacity, free space and volumes (name, role, volume group, file
count). Identifying values (serials, UUIDs) are reported raw here; the
harness's import step scrubs them before anything is committed.
"""
import glob
import json
import os
import struct
import sys
import uuid as uuidlib

CHOSEN = '/proc/device-tree/chosen'
APFS_ROLE = {0: '', 1: 'System', 2: 'User', 4: 'Recovery', 8: 'VM', 0x10: 'Preboot',
             0x20: 'Installer', 0x40: 'Data', 0x80: 'Baseband', 0xC0: 'Update',
             0x100: 'xART', 0x140: 'Hardware', 0x180: 'Backup', 0x200: 'Enterprise',
             0x280: 'Prelogin'}


def dt(path):
    try:
        with open(path, 'rb') as f:
            return f.read()
    except OSError:
        return None


def dt_str(path):
    v = dt(path)
    return None if v is None else v.split(b'\0')[0].decode(errors='replace')


def dt_u(path):
    v = dt(path)
    if v is None:
        return None
    return int.from_bytes(v, 'big')


class Dev:
    def __init__(self, path):
        self.fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)

    def read(self, off, n):
        return os.pread(self.fd, n, off)


def gpt(disk):
    d = Dev(disk)
    lbs = int(open('/sys/block/%s/queue/logical_block_size' % os.path.basename(disk)).read())
    hdr = d.read(lbs, 92)
    assert hdr[:8] == b'EFI PART', 'no GPT'
    entries_lba, count, esize = struct.unpack('<QII', hdr[72:88])
    disk_guid = str(uuidlib.UUID(bytes_le=hdr[56:72]))
    raw = d.read(entries_lba * lbs, count * esize)
    parts = []
    for i in range(count):
        e = raw[i * esize:(i + 1) * esize]
        if e[:16] == b'\0' * 16:
            continue
        first, last = struct.unpack('<QQ', e[32:48])
        parts.append({
            'index': i + 1,
            'type': str(uuidlib.UUID(bytes_le=e[:16])),
            'uuid': str(uuidlib.UUID(bytes_le=e[16:32])),
            'offset': first * lbs, 'size': (last - first + 1) * lbs,
            'name': e[56:128].decode('utf-16-le').rstrip('\0'),
        })
    size = int(open('/sys/block/%s/size' % os.path.basename(disk)).read()) * 512
    return {'disk_guid': disk_guid, 'block_size': lbs, 'size': size, 'partitions': parts}


def apfs(part):
    """Container geometry, spaceman free count and volume superblocks."""
    d = Dev(part)
    sb = d.read(0, 4096)
    if sb[32:36] != b'NXSB':
        return None
    bs = struct.unpack('<I', sb[36:40])[0]
    sb = d.read(0, bs)

    def nx_fields(b):
        return dict(xid=struct.unpack('<Q', b[16:24])[0],
                    block_count=struct.unpack('<Q', b[40:48])[0],
                    uuid=str(uuidlib.UUID(bytes=b[72:88])),
                    desc_blocks=struct.unpack('<I', b[104:108])[0] & 0x7fffffff,
                    desc_base=struct.unpack('<Q', b[112:120])[0],
                    spaceman_oid=struct.unpack('<Q', b[152:160])[0],
                    omap_oid=struct.unpack('<Q', b[160:168])[0],
                    max_fs=struct.unpack('<I', b[180:184])[0],
                    fs_oids=struct.unpack('<100Q', b[184:984]))
    best = nx_fields(sb)
    best_raw = sb
    base, nblocks = best['desc_base'], best['desc_blocks']
    descs = [d.read((base + i) * bs, bs) for i in range(nblocks)]
    for b in descs:
        if b[32:36] == b'NXSB':
            f = nx_fields(b)
            if f['xid'] > best['xid']:
                best, best_raw = f, b
    # checkpoint maps (type 0x0c) with the same xid map ephemeral oids
    eph = {}
    for b in descs:
        typ = struct.unpack('<I', b[24:28])[0] & 0xffff
        xid = struct.unpack('<Q', b[16:24])[0]
        if typ == 0x0c and xid == best['xid']:
            cnt = struct.unpack('<I', b[36:40])[0]
            for i in range(cnt):
                m = b[40 + i * 40:40 + (i + 1) * 40]
                _t, _s, _sz, _p, _fs, oid, paddr = struct.unpack('<IIIIQQQ', m)
                eph[oid] = paddr
    free = None
    sm = eph.get(best['spaceman_oid'])
    if sm is not None:
        s = d.read(sm * bs, bs)
        free = struct.unpack('<Q', s[48 + 24:48 + 32])[0] * bs
    # container object map: physical omap_phys -> B-tree root
    om = d.read(best['omap_oid'] * bs, bs)
    tree = struct.unpack('<Q', om[48:56])[0]
    vmap = {}

    def walk(paddr):
        n = d.read(paddr * bs, bs)
        flags, level, nkeys = struct.unpack('<HHI', n[32:40])
        toff, tlen = struct.unpack('<HH', n[40:44])
        keys = 56 + toff + tlen
        vend = bs - (40 if flags & 1 else 0)
        for i in range(nkeys):
            ko, vo = struct.unpack('<HH', n[56 + toff + i * 4:56 + toff + i * 4 + 4])
            oid, xid = struct.unpack('<QQ', n[keys + ko:keys + ko + 16])
            v = n[vend - vo:vend - vo + 16]
            if level == 0:
                _fl, _sz, p = struct.unpack('<IIQ', v)
                if oid not in vmap or vmap[oid][0] < xid:
                    vmap[oid] = (xid, p)
            else:
                walk(struct.unpack('<Q', v[:8])[0])
    walk(tree)
    vols = []
    for oid in best['fs_oids']:
        if oid == 0:
            continue
        if oid not in vmap:
            continue
        v = d.read(vmap[oid][1] * bs, bs)
        if v[32:36] != b'APSB':
            continue
        role = struct.unpack('<H', v[0x3C4:0x3C6])[0]
        vols.append({
            'name': v[0x2C0:0x3C0].split(b'\0')[0].decode(errors='replace'),
            'role': APFS_ROLE.get(role, hex(role)),
            'uuid': str(uuidlib.UUID(bytes=v[0xF0:0x100])),
            'group': str(uuidlib.UUID(bytes=v[0x3F0:0x400])),
            'files': struct.unpack('<Q', v[0xB8:0xC0])[0],
            'alloc_bytes': struct.unpack('<Q', v[0x58:0x60])[0] * bs,
        })
    return {'uuid': best['uuid'], 'block_size': bs, 'capacity': best['block_count'] * bs,
            'free': free, 'volumes': vols}


def main():
    disk = '/dev/nvme0n1'
    chosen = {}
    for name in sorted(os.listdir(CHOSEN)):
        if any(name.startswith(p) for p in ('asahi,', 'u-boot,')) and 'mac-address' not in name \
                and name not in ('asahi,efi-system-partition',):
            chosen[name] = dt_str(os.path.join(CHOSEN, name))
    comp = dt('/proc/device-tree/compatible').split(b'\0')
    g = gpt(disk)
    for p in g['partitions']:
        dev = '%sp%d' % (disk, p['index'])
        if p['type'] == 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b':
            try:
                bs = Dev(dev).read(0, 512)
                at = 0x47 if bs[0x52:0x5a].startswith(b'FAT32') else 0x2B
                p['fat_label'] = bs[at:at + 11].decode('ascii', 'replace').rstrip()
            except OSError as e:
                p['fat_label_error'] = repr(e)
        try:
            p['apfs'] = apfs(dev) if p['type'].startswith(('7c3457ef', '69646961', '52637672')) else None
        except Exception as e:  # report, never guess
            p['apfs_error'] = repr(e)
    out = {
        'schema': 1,
        'compatible': [c.decode() for c in comp if c],
        'model': dt_str('/proc/device-tree/model'),
        'chosen': chosen,
        'esp_partuuid': dt_str(CHOSEN + '/asahi,efi-system-partition'),
        'kernel': os.uname().release,
        'disk': g,
    }
    json.dump(out, sys.stdout, indent=1, sort_keys=True)


if __name__ == '__main__':
    main()
