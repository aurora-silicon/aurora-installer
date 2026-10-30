#!/usr/bin/env python3
"""Turn a raw collect-machine-profile.py capture into a public fixture.

This repository is public, so the fixture keeps only what the installer's
inspection reads and nothing that identifies the machine: no serial numbers,
no ECID, no MAC addresses, and every partition, container, volume and group
UUID replaced by a stable placeholder in order of first appearance.

    import-machine-profile.py RAW.json --name m2 --description '...' > fixtures/machines/m2.json
"""
import argparse
import json
import re
import sys

UUID = re.compile(r'\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\Z')
TYPES = {  # GPT partition types the inspection distinguishes; these are public constants
    '69646961-6700-11aa-aa11-00306543ecac', '7c3457ef-0000-11aa-aa11-00306543ecac',
    '52637672-7900-11aa-aa11-00306543ecac', 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b',
    '0fc63daf-8483-4772-8e79-3d69d8477de4',
}
ZERO = '00000000-0000-0000-0000-000000000000'


class Scrubber:
    def __init__(self):
        self.map = {}

    def __call__(self, value):
        value = value.lower()
        if value == ZERO:
            return None
        if value not in self.map:
            self.map[value] = '00000000-0000-4000-8000-%012x' % (len(self.map) + 1)
        return self.map[value]


def convert(raw, name, description, captured):
    scrub = Scrubber()
    compatible = raw['compatible']
    chosen = raw['chosen']
    parts = []
    for part in raw['disk']['partitions']:
        if part['type'] not in TYPES:
            raise SystemExit('unknown partition type %s; extend TYPES first' % part['type'])
        row = {'index': part['index'], 'type': part['type'], 'uuid': scrub(part['uuid']),
               'offset': part['offset'], 'size': part['size']}
        if 'fat_label' in part:
            row['fat_label'] = part['fat_label']
        if part.get('apfs'):
            a = part['apfs']
            row['apfs'] = {
                'uuid': scrub(a['uuid']), 'capacity': a['capacity'], 'free': a['free'],
                'volumes': [{'name': v['name'], 'role': v['role'], 'uuid': scrub(v['uuid']),
                             'group': scrub(v['group']), 'files': v['files'],
                             'alloc_bytes': v['alloc_bytes']} for v in a['volumes']],
            }
        elif part.get('apfs_error'):
            raise SystemExit('APFS read failed on partition %d: %s' % (part['index'], part['apfs_error']))
        parts.append(row)
    fixture = {
        'schema': 1, 'name': name, 'description': description, 'captured': captured,
        'source': 'macOS/test/conformance/collect-machine-profile.py (read-only, under Linux)',
        'device_identifier': compatible[0], 'soc': compatible[1].split(',')[1],
        'model': raw['model'],
        'firmware': {
            'system_iboot': chosen['asahi,iboot1-version'],
            'system_os': chosen['asahi,system-fw-version'],
            'stub_iboot': chosen['asahi,iboot2-version'],
            'stub_os': chosen['asahi,os-fw-version'],
        },
        'running': {
            'stage1': chosen.get('asahi,m1n1-stage1-version'),
            'stage2': chosen.get('asahi,m1n1-stage2-version'),
            'u_boot': chosen.get('u-boot,version'), 'kernel': raw['kernel'],
        },
        'disk': {'size': raw['disk']['size'], 'block_size': raw['disk']['block_size'],
                 'partitions': parts},
    }
    text = json.dumps(fixture, indent=1, sort_keys=True)
    for value in re.findall(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', text):
        if value.lower() not in TYPES and not value.startswith('00000000-0000-4000-8000-'):
            raise SystemExit('unscrubbed UUID left in fixture')
    return fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('raw')
    parser.add_argument('--name', required=True)
    parser.add_argument('--description', required=True)
    parser.add_argument('--captured', required=True)
    args = parser.parse_args()
    with open(args.raw) as f:
        raw = json.load(f)
    json.dump(convert(raw, args.name, args.description, args.captured), sys.stdout, indent=1, sort_keys=True)
    sys.stdout.write('\n')


if __name__ == '__main__':
    main()
