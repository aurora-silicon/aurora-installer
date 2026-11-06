#!/usr/bin/env python3
"""Simulate the catalog set the release train would sign after a support change.

The live Edge catalogs bind payload metadata that the producer assembled from
the supported-models.json of its day. A change to that list (a newly supported
Mac, or a board taken out of Stage 1 qualification) only reaches the matrix once
every profile is rebuilt, re-signed and adopted. This tool shows that result
ahead of time, so the matrix can be run "at the pin" for the new list:

- every live catalog gains one enabled model per added board, pointing at the
  same payload as every other Mac;
- each profile's live payload metadata gets the Stage 1 qualification that
  this tree's scripts/assemble-distribution-payload.py would write;
- the catalogs are signed with a throwaway key made here, whose raw public key
  is written as trust-root.ed25519.pub for conformance.py --trust-root.

Nothing is published or uploaded, and the app trust root is not touched.

    simulate-catalogs.py --cache DIR --output DIR [--add apple,jXXX ...]
    conformance.py ... --catalogs DIR --trust-root DIR/trust-root.ed25519.pub
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / 'scripts'))
import conformance  # noqa: E402
import supported_models  # noqa: E402

FIRMWARE = ['13.5', '14.8.3', '26.6', '26.6.2']


def qualified_machines():
    supported, _ = supported_models.load()
    unqualified = supported_models.stage1_unqualified()
    return {i.removeprefix('apple,') + 'ap': list(FIRMWARE) for i in supported if i not in unqualified}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--catalogs', default=conformance.DEFAULT_CATALOGS)
    parser.add_argument('--cache', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--add', nargs='*', default=[], help='device identifiers to enable in every catalog')
    args = parser.parse_args()
    Path(args.cache).mkdir(parents=True, exist_ok=True)
    out = args.output
    out.mkdir(parents=True, exist_ok=True)
    key = out / 'simulation-key.pem'
    if not key.exists():
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'ed25519', '-out', str(key)], check=True)
    der = subprocess.run(['openssl', 'pkey', '-in', str(key), '-pubout', '-outform', 'DER'],
                         capture_output=True, check=True).stdout
    (out / 'trust-root.ed25519.pub').write_bytes(der[-32:])
    qualified = qualified_machines()
    for distro in conformance.DISTROS:
        for desktop in conformance.DESKTOPS:
            profile = '%s-%s' % (distro, desktop)
            catalog, verified = conformance.load_catalog(args.catalogs, profile, args.cache)
            if not verified:
                raise SystemExit('live catalog signature did not verify: ' + profile)
            template = next(m for m in catalog['models'] if m['status'] == 'enabled')
            metadata = json.loads(conformance.fetch(template['metadataArtifact']['sourceURL'], args.cache))
            metadata['os_list'][0]['aurora_stage1']['qualified_machines'] = qualified
            data = (json.dumps(metadata, indent=2) + '\n').encode()
            directory = out / profile
            directory.mkdir(exist_ok=True)
            (directory / 'metadata.json').write_bytes(data)
            have = {m['deviceIdentifier'] for m in catalog['models']}
            models = []
            for model in catalog['models'] + [dict(template, deviceIdentifier=i) for i in args.add if i not in have]:
                model = json.loads(json.dumps(model))
                model['metadataDigest'] = 'sha256:' + hashlib.sha256(data).hexdigest()
                model['metadataArtifact'] = dict(model['metadataArtifact'], sizeBytes=len(data),
                                                 sourceURL=(directory / 'metadata.json').resolve().as_uri())
                models.append(model)
            catalog['models'] = models
            catalog['sequence'] += 1
            (directory / 'catalog.json').write_bytes((json.dumps(catalog, indent=2) + '\n').encode())
            subprocess.run(['openssl', 'pkeyutl', '-sign', '-inkey', str(key), '-rawin',
                            '-in', str(directory / 'catalog.json'), '-out', str(directory / 'catalog.json.sig')],
                           check=True)
            print('%s: %d models, %d boards qualified for the common Stage 1' % (profile, len(models), len(qualified)))


if __name__ == '__main__':
    main()
