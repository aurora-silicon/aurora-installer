#!/bin/sh
# SPDX-License-Identifier: MIT

set -e

cd "$(dirname "$0")"

PYTHON_VER=3.13.9
PYTHON_PKG=python-$PYTHON_VER-macos11.pkg
PYTHON_URI="https://www.python.org/ftp/python/$PYTHON_VER/$PYTHON_PKG"
WIMLIB_DEPLOYMENT_TARGET="12.3"
HIVEX_DEPLOYMENT_TARGET="12.3"
AEA_DEPLOYMENT_TARGET="14.0"

WIMLIB_VER="1.14.5"
WIMLIB_PKG="wimlib-$WIMLIB_VER.tar.gz"
WIMLIB_URI="https://wimlib.net/downloads/$WIMLIB_PKG"
WIMLIB_SHA256="84221a3abd5b91228f15f8e6065c335a336237b5738197b75bf419eea561a194"

HIVEX_VER="1.3.24"
HIVEX_PKG="hivex-$HIVEX_VER.tar.gz"
HIVEX_URI="https://download.libguestfs.org/hivex/$HIVEX_PKG"
HIVEX_SHA256="a52fa45cecc9a78adb2d28605d68261e4f1fd4514a778a5473013d2ccc8a193c"

M1N1="$PWD/m1n1"
AFW="$PWD/asahi_firmware"
SRC="$PWD/src"
TOOLS="$PWD/tools"
DATA="$PWD/data"
DL="$PWD/dl"
PACKAGE="$PWD/package"
RELEASES="$PWD/releases"
RELEASES_DEV="$PWD/releases-dev"

rm -rf "$PACKAGE"

mkdir -p "$DL" "$PACKAGE" "$RELEASES" "$RELEASES_DEV"
mkdir -p "$PACKAGE/bin"

echo "Determining version..."

[ -d .git ] && VER=$(git describe --always --dirty --tags)

if [ -z "$VER" ]; then
    if [ -e version.tag ]; then
        VER="$(cat version.tag)"
    else
        echo "Could not determine version!"
        exit 1
    fi
fi

echo "Version: $VER"

echo "Downloading installer components..."

cd "$DL"

echo " - Python"

if [ -e "$PYTHON_PKG" ]; then
    echo "Using existing $PYTHON_PKG"
else
    wget -Nc "$PYTHON_URI"
fi

if [ -r "$M1N1_STAGE1" ]; then
    echo "Using '$M1N1_STAGE1' as m1n1 stage1"
elif [ ! -r "$M1N1/Makefile" ]; then
    echo "m1n1 missing, did you forget to update the submodules?"
    exit 1
else
    echo "Building m1n1 stage 1..."

    # Do it twice in case of build system shenanigans with versions
    make -C "$M1N1" BUILD_DIR=build-stage1 RELEASE=1 CHAINLOADING=1 -j4
    make -C "$M1N1" BUILD_DIR=build-stage1 RELEASE=1 CHAINLOADING=1 -j4

    M1N1_STAGE1="$M1N1/build-stage1/m1n1.bin"
fi

if [ -z "${M1N1_STAGE2:-}" ] && [ -r "$M1N1/Makefile" ]; then
    echo "Building payload-free m1n1 stage 2..."

    make -C "$M1N1" BUILD_DIR=build-stage2 RELEASE=1 -j4
    make -C "$M1N1" BUILD_DIR=build-stage2 RELEASE=1 -j4

    M1N1_STAGE2="$M1N1/build-stage2/m1n1.bin"
elif [ -z "${M1N1_STAGE2:-}" ]; then
    echo "M1N1_STAGE2 is required when building without the m1n1 submodule"
    exit 1
elif [ ! -r "$M1N1_STAGE2" ]; then
    echo "Unable to read m1n1 stage 2 '$M1N1_STAGE2'"
    exit 1
else
    echo "Using '$M1N1_STAGE2' as m1n1 stage 2"
fi

echo "Copying files..."

# Preserve source symlinks on macOS. BSD cp -r dereferences the
# asahi_firmware link, which makes the following plain rm fail.
cp -RP "$SRC"/* "$PACKAGE/"
rm "$PACKAGE/asahi_firmware"
cp -r "$AFW" "$PACKAGE/"
# Test and development runs can leave host-version bytecode in either source
# tree. Never make those caches part of the portable installer payload.
find "$PACKAGE" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
find "$PACKAGE" -type d -name __pycache__ -empty -delete
cp "$DATA/installer_data.json" "$PACKAGE/installer_data.json"
cp "$DATA/windows-iso.json" "$PACKAGE/windows-iso.json"
if [ -r "$LOGO" ]; then
    cp "$LOGO" "$PACKAGE/logo.icns"
elif [ ! -r "$M1N1/data/aurora-logo-src.png" ]; then
    echo "Aurora artwork missing, did you forget to update the m1n1 submodule?"
    exit 1
else
    python3 "$TOOLS/make-icns.py" \
        "$M1N1/data/aurora-logo-src.png" "$PACKAGE/logo.icns"
fi
mkdir -p "$PACKAGE/boot"
cp "$M1N1_STAGE1" "$PACKAGE/boot/m1n1.bin"

echo "Packaging replaceable m1n1 stage 2..."

STAGE2_TREE="$PACKAGE/.aurora-stage2"
mkdir -p "$STAGE2_TREE/esp/m1n1" "$STAGE2_TREE/esp/aurora" "$PACKAGE/os"
cp "$M1N1_STAGE2" "$STAGE2_TREE/esp/m1n1/boot.bin"
cp "$DATA/stage2.json" "$STAGE2_TREE/esp/aurora/stage2.json"
(
    cd "$STAGE2_TREE"
    zip -q -r "$PACKAGE/os/aurora-stage2-proxy.zip" esp
)
rm -rf "$STAGE2_TREE"

echo "Packaging Windows deployment payload..."

if [ ! -r "$DL/$WIMLIB_PKG" ]; then
    (cd "$DL" && wget -Nc "$WIMLIB_URI")
fi
echo "$WIMLIB_SHA256  $DL/$WIMLIB_PKG" | shasum -a 256 -c -

echo "Building bundled wimlib-imagex for macOS $WIMLIB_DEPLOYMENT_TARGET+..."
WIMLIB_BUILD_ROOT=$(mktemp -d /private/tmp/aurora-wimlib-build.XXXXXX)
WIMLIB_PREFIX="$WIMLIB_BUILD_ROOT/install"
tar xf "$DL/$WIMLIB_PKG" -C "$WIMLIB_BUILD_ROOT"
(
    cd "$WIMLIB_BUILD_ROOT/wimlib-$WIMLIB_VER"
    MACOSX_DEPLOYMENT_TARGET="$WIMLIB_DEPLOYMENT_TARGET" ./configure \
        --prefix="$WIMLIB_PREFIX" \
        --disable-shared \
        --enable-static \
        --without-fuse \
        --without-ntfs-3g
    MACOSX_DEPLOYMENT_TARGET="$WIMLIB_DEPLOYMENT_TARGET" make -j4
    MACOSX_DEPLOYMENT_TARGET="$WIMLIB_DEPLOYMENT_TARGET" make install
)
mkdir -p "$PACKAGE/bin" "$PACKAGE/licenses/wimlib" "$PACKAGE/sources"
cp "$WIMLIB_PREFIX/bin/wimlib-imagex" "$PACKAGE/bin/wimlib-imagex"
codesign --force --sign - "$PACKAGE/bin/wimlib-imagex"
chmod 0755 "$PACKAGE/bin/wimlib-imagex"
rm -rf "$WIMLIB_BUILD_ROOT"

cp "$DL/$WIMLIB_PKG" "$PACKAGE/sources/$WIMLIB_PKG"
tar -xOf "$DL/$WIMLIB_PKG" "wimlib-$WIMLIB_VER/COPYING" \
    > "$PACKAGE/licenses/wimlib/COPYING"
tar -xOf "$DL/$WIMLIB_PKG" "wimlib-$WIMLIB_VER/COPYING.GPLv3" \
    > "$PACKAGE/licenses/wimlib/COPYING.GPLv3"
tar -xOf "$DL/$WIMLIB_PKG" "wimlib-$WIMLIB_VER/COPYING.LGPL" \
    > "$PACKAGE/licenses/wimlib/COPYING.LGPL"
cp "$DATA/wimlib-NOTICE.txt" "$PACKAGE/licenses/wimlib/NOTICE.txt"

if [ ! -r "$DL/$HIVEX_PKG" ]; then
    (cd "$DL" && wget -Nc "$HIVEX_URI")
fi
echo "$HIVEX_SHA256  $DL/$HIVEX_PKG" | shasum -a 256 -c -

echo "Building BCD TESTSIGNING helper for macOS $HIVEX_DEPLOYMENT_TARGET+..."
HIVEX_BUILD_ROOT=$(mktemp -d /private/tmp/aurora-hivex-build.XXXXXX)
tar xf "$DL/$HIVEX_PKG" -C "$HIVEX_BUILD_ROOT"
(
    cd "$HIVEX_BUILD_ROOT/hivex-$HIVEX_VER"
    # New Apple linkers spell the map-file option differently.
    perl -pi -e 's/"-Wl,-M -Wl,/"-Wl,-map -Wl,/' configure
    MACOSX_DEPLOYMENT_TARGET="$HIVEX_DEPLOYMENT_TARGET" ./configure \
        --disable-ocaml \
        --disable-perl \
        --disable-python \
        --disable-ruby \
        --disable-nls \
        --without-readline \
        --disable-static \
        --enable-shared \
        --disable-silent-rules
    MACOSX_DEPLOYMENT_TARGET="$HIVEX_DEPLOYMENT_TARGET" make -C gnulib/lib -j4
    MACOSX_DEPLOYMENT_TARGET="$HIVEX_DEPLOYMENT_TARGET" make -C lib -j4
    cc -target "arm64-apple-macosx$HIVEX_DEPLOYMENT_TARGET" \
        -Iinclude "$TOOLS/bcd-set-testsigning.c" \
        -Llib/.libs -lhivex \
        -Wl,-rpath,@executable_path/../lib \
        -o "$HIVEX_BUILD_ROOT/bcd-set-testsigning"
    install_name_tool -change /usr/local/lib/libhivex.0.dylib \
        @rpath/libhivex.0.dylib "$HIVEX_BUILD_ROOT/bcd-set-testsigning"
    install_name_tool -id @rpath/libhivex.0.dylib lib/.libs/libhivex.0.dylib
)
mkdir -p "$PACKAGE/lib" "$PACKAGE/licenses/hivex"
cp "$HIVEX_BUILD_ROOT/hivex-$HIVEX_VER/lib/.libs/libhivex.0.dylib" \
    "$PACKAGE/lib/libhivex.0.dylib"
cp "$HIVEX_BUILD_ROOT/bcd-set-testsigning" "$PACKAGE/bin/bcd-set-testsigning"
codesign --force --sign - "$PACKAGE/lib/libhivex.0.dylib"
codesign --force --sign - "$PACKAGE/bin/bcd-set-testsigning"
chmod 0755 "$PACKAGE/bin/bcd-set-testsigning"
rm -rf "$HIVEX_BUILD_ROOT"

cp "$DL/$HIVEX_PKG" "$PACKAGE/sources/$HIVEX_PKG"
tar -xOf "$DL/$HIVEX_PKG" "hivex-$HIVEX_VER/LICENSE" \
    > "$PACKAGE/licenses/hivex/LICENSE"
cp "$DATA/hivex-NOTICE.txt" "$PACKAGE/licenses/hivex/NOTICE.txt"

WINDOWS_TREE="$PACKAGE/.aurora-windows"
mkdir -p "$WINDOWS_TREE/esp/m1n1" "$WINDOWS_TREE/esp/aurora"
mkdir -p "$WINDOWS_TREE/windows/deploy"

# The shipping stage 2 remains the payload-free proxy build. A future
# autonomous m1n1/Mu image can be supplied at build time without changing
# the partition map or the stage-1 chainload path.
WINDOWS_STAGE2="$M1N1_STAGE2"
WINDOWS_STAGE2_MANIFEST="$DATA/stage2.json"
if [ -n "${AURORA_WINDOWS_STAGE2:-}" ] || [ -n "${AURORA_WINDOWS_STAGE2_MANIFEST:-}" ]; then
    if [ ! -r "${AURORA_WINDOWS_STAGE2:-}" ] || [ ! -r "${AURORA_WINDOWS_STAGE2_MANIFEST:-}" ]; then
        echo "AURORA_WINDOWS_STAGE2 and AURORA_WINDOWS_STAGE2_MANIFEST must be supplied together"
        exit 1
    fi
    WINDOWS_STAGE2="$AURORA_WINDOWS_STAGE2"
    WINDOWS_STAGE2_MANIFEST="$AURORA_WINDOWS_STAGE2_MANIFEST"
fi
python3 - "$WINDOWS_STAGE2_MANIFEST" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
if manifest.get("schema") != 1 or manifest.get("path") != "m1n1/boot.bin":
    raise SystemExit("Windows stage-2 manifest must describe m1n1/boot.bin schema 1")
if manifest.get("replaceable") is not True:
    raise SystemExit("Windows stage-2 manifest must retain the replaceable update contract")
if not manifest.get("mode") or not manifest.get("boot_method"):
    raise SystemExit("Windows stage-2 manifest must describe its mode and boot method")
PY
cp "$WINDOWS_STAGE2" "$WINDOWS_TREE/esp/m1n1/boot.bin"
cp "$WINDOWS_STAGE2_MANIFEST" "$WINDOWS_TREE/esp/aurora/stage2.json"
python3 - "$WINDOWS_STAGE2_MANIFEST" "$PACKAGE/installer_data.json" <<'PY'
import json
import pathlib
import sys

manifest_path, installer_path = map(pathlib.Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text())
data = json.loads(installer_path.read_text())
windows_options = [entry for entry in data["os_list"] if "windows_deployment" in entry]
if len(windows_options) != 1:
    raise SystemExit("installer metadata must have exactly one Windows deployment option")
deployment = windows_options[0]["windows_deployment"]
deployment["stage2_mode"] = manifest["mode"]
deployment["boot_method"] = manifest["boot_method"]
installer_path.write_text(json.dumps(data, indent=4) + "\n")
PY
cp "$DATA/windows-driver-pack.json" "$WINDOWS_TREE/windows/driver-pack.json"
cp "$DATA/windows/startnet.cmd" "$WINDOWS_TREE/windows/deploy/startnet.cmd"
cp "$DATA/windows/aurora-deploy.cmd" "$WINDOWS_TREE/windows/deploy/aurora-deploy.cmd"
cp "$DATA/windows/SetupComplete.cmd" "$WINDOWS_TREE/windows/deploy/SetupComplete.cmd"
(
    cd "$WINDOWS_TREE"
    zip -q -r "$PACKAGE/os/aurora-windows-bootstrap.zip" esp windows
)
rm -rf "$WINDOWS_TREE"

echo "Building AEA key helper..."

if [ -n "${AEA_KEY_HELPER:-}" ] && [ -r "$AEA_KEY_HELPER" ]; then
    echo "Using '$AEA_KEY_HELPER' as AEA key helper"
    cp "$AEA_KEY_HELPER" "$PACKAGE/bin/aea-key"
elif command -v xcrun >/dev/null 2>&1; then
    xcrun swiftc -target "arm64-apple-macosx$AEA_DEPLOYMENT_TARGET" \
        -O -framework CryptoKit -framework Foundation \
        "$TOOLS/aea-key.swift" -o "$PACKAGE/bin/aea-key"
else
    echo "AEA_KEY_HELPER is required when building without macOS swiftc"
    exit 1
fi
chmod 0755 "$PACKAGE/bin/aea-key"

echo "Extracting Python framework..."

mkdir -p "$PACKAGE/Frameworks/Python.framework"
PYTHON_FRAMEWORK="$PACKAGE/Frameworks/Python.framework"

# test if libarchive's bsdtar is capable of extracting the payload
# libarchive 3.7.2 (Ubuntu 24.04) is broken while 3.8.5 (Ubuntu 26.04) works
if bsdtar -tf "$DL/$PYTHON_PKG" Python_Framework.pkg/Payload > /dev/null 2>&1; then
    bsdtar -xOf "$DL/$PYTHON_PKG" Python_Framework.pkg/Payload | zcat | \
        (cd "$PACKAGE/Frameworks/Python.framework" && cpio -i)
elif command -v xar > /dev/null 2>&1; then
    XAR_TMP="$(mktemp -d)"
    xar -x -f "$DL/$PYTHON_PKG" -C "$XAR_TMP"
    gzip -dc "$XAR_TMP/Python_Framework.pkg/Payload" | \
        (cd "$PACKAGE/Frameworks/Python.framework" && cpio -i)
    rm -rf "$XAR_TMP"
else
    if command -v 7z >/dev/null 2>&1; then
        SEVENZIP=7z
    elif command -v 7zz >/dev/null 2>&1; then
        SEVENZIP=7zz
    else
        echo "7z or 7zz is required when bsdtar cannot extract the Python package"
        exit 1
    fi
    "$SEVENZIP" x -so "$DL/$PYTHON_PKG" Python_Framework.pkg/Payload | gzip -dc | \
        (cd "$PYTHON_FRAMEWORK" && cpio -i)
fi

cd "$PACKAGE/Frameworks/Python.framework/Versions/Current"

echo "Slimming down Python..."

rm -rf include share
cd lib
rm -rf -- tdb* tk* Tk* libtk* *tcl*
cd python3.*
rm -rf test ensurepip idlelib
cd lib-dynload
rm -f _test* _tkinter*
    

echo "Copying certificates..."

if certs="$(python3 -c 'import certifi; print(certifi.where())' 2>/dev/null)"; then
    :
elif [ -r /etc/ssl/cert.pem ]; then
    certs=/etc/ssl/cert.pem
elif [ -r /etc/ssl/certs/ca-certificates.crt ]; then
    certs=/etc/ssl/certs/ca-certificates.crt
else
    echo "No CA certificate bundle found (install certifi or provide a system CA bundle)"
    exit 1
fi
cp "$certs" "$PACKAGE/Frameworks/Python.framework/Versions/Current/etc/openssl/cert.pem"

echo "Packaging installer..."

cd "$PACKAGE"

echo "$VER" > version.tag

PKGFILE="$RELEASES/installer-$VER.tar.gz"
LATEST="$RELEASES/latest"

tar czf "$PKGFILE" .
echo "$VER" > "$LATEST"

echo
echo "Built package: $(basename "$PKGFILE")"
