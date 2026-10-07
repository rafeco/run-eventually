#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if ! xcodebuild -version >/dev/null 2>&1; then
    compatible_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
    if [ -d "$compatible_sdk" ]; then export SDKROOT="$compatible_sdk"; fi
    export CLANG_MODULE_CACHE_PATH=/private/tmp/run-eventually-clang-cache
fi
mkdir -p Assets .build/AppIcon.iconset
swift scripts/generate-app-icon.swift Assets/AppIcon.png
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png \
        --out ".build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Assets/AppIcon.png \
        --out ".build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns .build/AppIcon.iconset -o Assets/AppIcon.icns
