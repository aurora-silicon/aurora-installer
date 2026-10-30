#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:?preview or recovery}"
OUT="${2:-build}"
[[ "$MODE" == "preview" || "$MODE" == "recovery" ]] || exit 2
export AURORA_RECOVERY_BUILD="$MODE"
APP="$OUT/Aurora Installer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AuroraLogo.png "$APP/Contents/Resources/AuroraLogo.png"
cp ../Packaging/AuroraInstaller.icns "$APP/Contents/Resources/AuroraInstaller.icns"
if [[ $MODE == "preview" ]]; then
  cp ../Packaging/DistributionIcons/aurora.icns "$APP/Contents/Resources/"
fi
mkdir -p "$APP/Contents/Resources/en.lproj"
cp Resources/en.lproj/InfoPlist.strings "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
# Build the standalone Recovery target with XcodeBuildMCP before packaging.
if command -v "${XCODEBUILDMCP:-xcodebuildmcp}" >/dev/null 2>&1; then
  "${XCODEBUILDMCP:-xcodebuildmcp}" swift-package build --package-path "$PWD" --configuration release
else
  # Release builders need only Xcode's bundled Swift tools.
  xcrun swift build --package-path "$PWD" --configuration release
fi
./test-all.sh "$OUT/checks"
# Released templates and the payloads built from them name the executable
# OmarchyRecovery, and installers check that name, so the bundle keeps it.
cp .build/release/AuroraRecovery "$APP/Contents/MacOS/OmarchyRecovery"
[[ "$("$APP/Contents/MacOS/OmarchyRecovery" --build-mode)" == "$MODE" ]]
# The small Recovery OS may omit frameworks present in a full macOS install.
# Recovery stubs can omit UI and hashing frameworks present in full macOS.
dependencies=$(xcrun otool -L "$APP/Contents/MacOS/OmarchyRecovery")
if [[ $dependencies == *'/SwiftUI.framework/'* ||
      $dependencies == *'/Combine.framework/'* ||
      $dependencies == *'/CryptoKit.framework/'* ||
      $dependencies == *'/CryptoTokenKit.framework/'* ]]; then
  echo 'Recovery executable links a framework unavailable in older Recovery OS' >&2
  exit 1
fi
# The macOS 13.5 Recovery stub loads only these Swift libraries. It has no
# AppKit overlay, so a call such as NSSound.beep() stops Recovery launching.
# Weak-linked libraries are allowed.
while read -r lib; do
  case $lib in
    libswiftCore.dylib | libswiftDarwin.dylib | libswiftDispatch.dylib | libswiftObjectiveC.dylib | libswift_Concurrency.dylib) ;;
    *)
      echo "Recovery executable requires $lib, which older Recovery OS lacks" >&2
      exit 1
      ;;
  esac
done < <(printf '%s\n' "$dependencies" | grep '/usr/lib/swift/' | grep -v ', weak)' | sed -E 's#.*/usr/lib/swift/([^ ]+).*#\1#')
if grep -REn '^[[:space:]]*import[[:space:]]+(SwiftUI|Combine|CryptoKit|CryptoTokenKit)' Sources; then
  echo 'Recovery sources import a framework unavailable in older Recovery OS' >&2
  exit 1
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OmarchyRecovery</string>
<key>CFBundleIdentifier</key><string>org.aurorasilicon.recovery.$MODE</string>
<key>OmarchyRecoveryBuildMode</key><string>$MODE</string>
<key>OmarchyRecoveryDataLayout</key><string>external-install-data-v1</string>
<key>CFBundleName</key><string>Aurora Installer</string>
<key>CFBundleDisplayName</key><string>Aurora Installer</string>
<key>CFBundleIconFile</key><string>AuroraInstaller.icns</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework AppKit Tests/BundleLookupCheck.m -o "$OUT/bundle-lookup-check"
"$OUT/bundle-lookup-check" "$(cd "$APP" && pwd)"
if [[ "$MODE" == "recovery" ]]; then
  python3 ../scripts/recovery_payload.py "$APP" "$OUT/omarchy-recovery-app.json"
fi
printf 'Built %s\n' "$APP"
