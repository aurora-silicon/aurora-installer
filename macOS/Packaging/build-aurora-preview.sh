#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
output="${1:-$root/build-aurora-preview}"
runner="${XCODEBUILDMCP:-xcodebuildmcp}"
"$runner" swift-package build --package-path "$root" --configuration debug
binary="$(cd "$root" && xcrun swift build --configuration debug --show-bin-path)/OmarchyAppleInstallerApp"
app="$output/Aurora Installer.app"
[[ ! -e $app ]] || { echo "Output already exists: $app" >&2; exit 1; }
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/AuroraInstallerPreview"
cp "$root/Resources/"*.png "$app/Contents/Resources/"
cp -R "$root/Resources/BrandSources" "$app/Contents/Resources/BrandSources"
cp "$root/Packaging/AuroraInstaller.icns" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.aurorasilicon.installer.preview</string>
<key>CFBundleExecutable</key><string>AuroraInstallerPreview</string>
<key>CFBundleName</key><string>Aurora Installer</string>
<key>CFBundleDisplayName</key><string>Aurora Installer</string>
<key>CFBundleIconFile</key><string>AuroraInstaller</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>AuroraPreviewOnly</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
