#!/bin/sh
# Builds ./lariska. Needs Xcode Command Line Tools (xcode-select --install).
set -eu
cd "$(dirname "$0")"
[ "$(uname -s)" = "Darwin" ] || { echo "macOS only"; exit 1; }
command -v swift >/dev/null 2>&1 || { echo "Swift not found: xcode-select --install"; exit 1; }
swift build -c release
cp .build/release/lariska ./lariska
codesign -s - -f lariska >/dev/null 2>&1   # Apple Silicon refuses unsigned binaries
echo "built ./lariska"
