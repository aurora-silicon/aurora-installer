#!/usr/bin/env python3
"""Assemble existing synthetic firmware vectors into a selected restore input."""
import argparse
import base64
import io
import json
from pathlib import Path
import plistlib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'Tests/AuroraAppleInstallerTrustCoreTests/Fixtures/native-finishing.json'


def der(tag, data):
    length = len(data)
    encoded = bytes([length]) if length < 128 else bytes([0x80 + (length.bit_length() + 7) // 8]) + length.to_bytes((length.bit_length() + 7) // 8, 'big')
    return bytes([tag]) + encoded + data


def generate():
    source = json.loads((ROOT / 'Tests/AuroraAppleInstallerTrustCoreTests/Fixtures/native-stub-files.json').read_text())
    generic = json.loads((ROOT / 'Tests/AuroraFirmwareTests/Fixtures/generic-firmware.json').read_text())
    with zipfile.ZipFile(io.BytesIO(base64.b64decode(source['vectors'][0]['archive']))) as archive:
        files = {name: archive.read(name) for name in archive.namelist()}
    manifest = plistlib.loads(files['BuildManifest.plist'])
    identity = next(x for x in manifest['BuildIdentities'] if x['ApBoardID'] == '0x01')
    identity['Manifest']['Multitouch'] = dict(Info=dict(Path='Firmware/synthetic.im4p', IsFUDFirmware=True))
    files['BuildManifest.plist'] = plistlib.dumps(manifest)
    touch = next(x for x in generic['vectors'] if x['name'] == 'trackpad-j700')
    files['Firmware/synthetic.im4p'] = base64.b64decode(touch['inputs']['image'])
    controller = next(x for x in generic['vectors'] if x['name'] == 'controller-complete')
    kernel = base64.b64decode(controller['inputs']['kernel'])
    files['kernelcache.fixture'] = der(0x30, der(0x16, b'IM4P') + der(0x16, b'krnl') + der(0x16, b'synthetic') + der(4, kernel))
    def packed():
        result = io.BytesIO()
        with zipfile.ZipFile(result, 'w') as archive:
            for name, data in sorted(files.items()):
                info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
                info.external_attr = 0o100644 << 16
                archive.writestr(info, data)
        return base64.b64encode(result.getvalue()).decode()
    result = dict(archive=packed())
    for name, directory in (('wifi-dimensions', 'wifi'), ('bluetooth-AMKOR', 'bluetooth')):
        vector = next(x for x in generic['vectors'] if x['name'] == name)
        for member, data in vector['inputs'].items():
            result['radio/' + directory + '/' + member] = data
    for machine in ('j314s', 'j274'):
        identity['Info']['DeviceClass'] = machine + 'ap'
        if machine == 'j314s':
            touch = next(x for x in generic['vectors'] if x['name'] == 'trackpad-j314s')
            files['Firmware/synthetic.im4p'] = base64.b64decode(touch['inputs']['image'])
        else:
            del identity['Manifest']['Multitouch']
            del files['Firmware/synthetic.im4p']
        files['BuildManifest.plist'] = plistlib.dumps(manifest)
        result['archive-' + machine] = packed()
    return json.dumps(result, sort_keys=True, separators=(',', ':')) + '\n'


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    value = generate()
    if args.write:
        OUTPUT.write_text(value)
    elif OUTPUT.read_text() != value:
        raise SystemExit('stale native finishing vectors')
    print('Verified synthetic selected-identity firmware finishing input')
