#!/bin/sh
set -eu

BASE_URL="${M5_BASE_URL:-http://192.168.68.61:8088}"
ARCHIVE="m5-j813ap-tethered-installer.tar.gz"
WORKDIR="$(mktemp -d /tmp/asahi-m5.XXXXXX)"

export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

cd "$WORKDIR"
curl --fail --location --remote-name "$BASE_URL/$ARCHIVE"
curl --fail --location --remote-name "$BASE_URL/$ARCHIVE.sha256"
shasum -a 256 -c "$ARCHIVE.sha256"
tar xzf "$ARCHIVE"

exec ./install-m5-tethered.sh
