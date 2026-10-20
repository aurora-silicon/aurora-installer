#!/bin/bash
# Build only the locked qualification reference; never execute archived code.
set -euo pipefail
fail() { echo "prepare-reference-runtime: $*" >&2; exit 1; }
(( $# == 1 )) || fail "usage: prepare-reference-runtime.sh NEW_ABSOLUTE_OUTPUT"
root=$(cd "$(dirname "$0")/.." && pwd -P)
output=$1
[[ $output == /* && ! -e $output && ! -L $output && -d ${output%/*} ]] || fail "unsafe output path"
free_kib=$(df -Pk "${output%/*}" | awk 'NR == 2 {print $4}')
[[ $free_kib =~ ^[0-9]+$ ]] && (( free_kib >= 10747904 )) || fail "reference build requires 10 GiB plus temporary headroom"
scratch=$(mktemp -d "${output%/*}/aurora-reference.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
read -r filename digest bytes < <(python3 "$root/Packaging/read-validation-engine.py")
python3 - "$root/Engine/source-lock.json" "$scratch" <<'PY'
import hashlib,json,sys,urllib.request
from pathlib import Path
lock=json.loads(Path(sys.argv[1]).read_text())
build=lock['incremental_build']
directory=Path(sys.argv[2])
for url in [build['base_url'], *build.get('base_mirror_urls', [])]:
    target=directory/'base.tar.gz'
    try:
        digest=hashlib.sha256()
        size=0
        with urllib.request.urlopen(url, timeout=60) as response, target.open('xb') as output:
            while chunk:=response.read(65536):
                size+=len(chunk)
                if size>build['base_size_bytes']: raise ValueError('oversized base archive')
                digest.update(chunk)
                output.write(chunk)
        if size!=build['base_size_bytes'] or digest.hexdigest()!=build['base_sha256']:
            raise ValueError('base archive identity mismatch')
        break
    except Exception:
        target.unlink(missing_ok=True)
else:
    raise SystemExit('Could not authenticate the locked base or its mirrors')
upstream=lock['upstream_installer']
(directory/'repository').write_text(upstream['repository'])
(directory/'revision').write_text(upstream['commit'])
PY
repository=$(cat "$scratch/repository")
revision=$(cat "$scratch/revision")
[[ $repository == https://github.com/AsahiLinux/asahi-installer.git && $revision =~ ^[0-9a-f]{40}$ ]] \
  || fail "unqualified reference source"
git clone --quiet --filter=blob:none --no-checkout "$repository" "$scratch/source"
git -C "$scratch/source" checkout --quiet --detach "$revision"
git -C "$scratch/source" submodule update --quiet --init --recursive
python3 -B "$root/Engine/rebuild-python-overlay.py" "$scratch/source" "$scratch/base.tar.gz" "$scratch/$filename"
python3 - "$scratch/$filename" "$digest" "$bytes" <<'PY'
import hashlib,sys
from pathlib import Path
path=Path(sys.argv[1])
assert path.stat().st_size==int(sys.argv[3]), 'reference size differs from pin'
with path.open('rb') as source:
    assert hashlib.file_digest(source,'sha256').hexdigest()==sys.argv[2], 'reference digest differs from pin'
PY
mv -n "$scratch/$filename" "$output"
[[ ! -e $scratch/$filename ]] || fail "output appeared during reference build"
printf '%s\n' "$output"
