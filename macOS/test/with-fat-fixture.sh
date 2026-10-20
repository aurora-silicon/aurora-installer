#!/bin/bash
# Run native filesystem qualification on an exclusively owned disposable image.
set -euo pipefail
[[ $(uname -s) == Darwin ]] || { echo 'A macOS fixture host is required.' >&2; exit 1; }
(( $# > 0 )) || { echo 'A fixture test command is required.' >&2; exit 1; }
fixture_root=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/aurora-fat.XXXXXX")
fixture_device=
fixture_attached=false
fixture_verified=false
cleanup() {
  result=$?
  trap - EXIT
  if [[ $fixture_attached == true && ( -z $fixture_device || $fixture_verified != true ) ]]; then
    echo "Retained potentially attached fixture for ownership review: $fixture_root" >&2
    (( result != 0 )) || result=1
    exit "$result"
  fi
  if [[ -n $fixture_device ]]; then
    if ! hdiutil detach "$fixture_device"; then
      echo "Retained owned fixture after detach failure: $fixture_root" >&2
      (( result != 0 )) || result=1
      exit "$result"
    fi
  fi
  rm -rf -- "$fixture_root"
  exit "$result"
}
trap cleanup EXIT
fixture_free_kib=$(df -Pk "$fixture_root" | awk 'NR == 2 {print $4}')
[[ $fixture_free_kib =~ ^[0-9]+$ ]] && (( fixture_free_kib >= 10616832 ))
hdiutil create -size 128m -layout NONE -fs MS-DOS -volname AURORATEST "$fixture_root/volume.dmg" > "$fixture_root/create.log"
# Attachment can partially succeed even when parsing or validation later fails.
fixture_attached=true
hdiutil attach -nomount -plist "$fixture_root/volume.dmg" > "$fixture_root/attach.plist"
fixture_device=$(python3 - "$fixture_root/attach.plist" <<'PY'
import plistlib,re,sys
with open(sys.argv[1],'rb') as f: info=plistlib.load(f)
values=[x['dev-entry'] for x in info['system-entities'] if re.fullmatch(r'/dev/disk[0-9]+',x.get('dev-entry',''))]
assert len(values)==1, 'Ambiguous disposable image attachment'
print(values[0])
PY
)
hdiutil info -plist > "$fixture_root/images.plist"
python3 - "$fixture_root/images.plist" "$fixture_root/volume.dmg" "$fixture_device" <<'PY'
import os,plistlib,sys
with open(sys.argv[1],'rb') as f: info=plistlib.load(f)
images=[x for x in info['images'] if os.path.realpath(x.get('image-path',''))==os.path.realpath(sys.argv[2])]
assert len(images)==1, 'Disposable image identity changed'
assert any(x.get('dev-entry')==sys.argv[3] for x in images[0]['system-entities']), 'Device does not belong to owned image'
PY
fixture_verified=true
sudo -n /sbin/newfs_msdos -F 32 -v AURORATEST "/dev/r${fixture_device#/dev/}"
mkdir "$fixture_root/mounted"
/usr/sbin/diskutil mount -mountPoint "$fixture_root/mounted" "$fixture_device"
export AURORA_ESP_FAT_ROOT="$fixture_root/mounted"
"$@"
