#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

if xcodebuild -version >/dev/null 2>&1; then
    swift test
else
    compatible_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
    if [ -d "$compatible_sdk" ]; then
        export SDKROOT="$compatible_sdk"
    fi
    export CLANG_MODULE_CACHE_PATH=/private/tmp/run-eventually-clang-cache
    export SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/run-eventually-swiftpm-cache
    frameworks=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    plugins=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
    swift test --disable-sandbox \
        -Xswiftc -F -Xswiftc "$frameworks" \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xswiftc -plugin-path -Xswiftc "$plugins" \
        -Xlinker -F -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$frameworks"
fi

swift run --disable-sandbox run-eventually-verify
/usr/bin/python3 scripts/test-dev-restart.py
