#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

# The installed Command Line Tools SDK and compiler differ on this Mac. Prefer
# the compatible SDK when a full Xcode installation is not selected.
if ! xcodebuild -version >/dev/null 2>&1; then
    compatible_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
    if [ -d "$compatible_sdk" ]; then
        export SDKROOT="$compatible_sdk"
    fi
    export CLANG_MODULE_CACHE_PATH=/private/tmp/run-eventually-clang-cache
    export SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/run-eventually-swiftpm-cache
fi

swift build --disable-sandbox

app_dir="$project_dir/.build/RunEventually.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp "$project_dir/.build/debug/run-eventually-desktop" "$app_dir/Contents/MacOS/"
cp "$project_dir/.build/debug/run-eventually" "$app_dir/Contents/MacOS/"
cp "$project_dir/Assets/AppIcon.icns" "$app_dir/Contents/Resources/"

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>run-eventually-desktop</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.rafeco.RunEventually</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Run Eventually</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app_dir/Contents/MacOS/run-eventually"
codesign --force --sign - "$app_dir"
echo "$app_dir"
