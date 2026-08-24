#!/bin/sh
set -e

cd "$(dirname "$0")"
base="$PWD"

if [ -e $HOME/.cargo/env ] ; then
    source $HOME/.cargo/env
fi

export INSTALLER_BASE=.
export REPO_BASE=.

make -C "m1n1" BUILD_DIR=build-stage1 RELEASE=1 CHAINLOADING=1 -j4
make -C "m1n1" BUILD_DIR=build-stage2 RELEASE=1 -j4

sudo rm -rf /tmp/aurora-install
mkdir -p /tmp/aurora-install

git describe --tags --always --dirty > /tmp/aurora-install/version.tag

cd /tmp/aurora-install
ln -sf "$base/src"/* .
ln -sf "$base/asahi_firmware" .
mkdir -p boot
ln -sf "$base/m1n1/build-stage1/m1n1.bin" boot/m1n1.bin
python3 "$base/tools/make-icns.py" "$base/m1n1/data/aurora-logo-src.png" logo.icns
ln -sf "$base/data/installer_data.json" installer_data.json
mkdir -p os stage2/esp/m1n1 stage2/esp/aurora
ln -sf "$base/m1n1/build-stage2/m1n1.bin" stage2/esp/m1n1/boot.bin
ln -sf "$base/data/stage2.json" stage2/esp/aurora/stage2.json
(cd stage2 && zip -q -r ../os/aurora-stage2-proxy.zip esp)
rm -rf stage2

sudo -E python3 main.py
