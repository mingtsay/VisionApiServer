#!/usr/bin/env bash
#
# Build VisionApiServer for Release.
#
# Usage:
#   ./build.sh                 # build all: arm64, x86_64, universal
#   ./build.sh arm64           # arm64 only
#   ./build.sh x86_64           # x86_64 only
#   ./build.sh universal       # universal (arm64 + x86_64)
#
# Version overrides for CI/CD (both optional):
#   MARKETING_VERSION       - sets CFBundleShortVersionString (e.g. 1.2.3)
#   CURRENT_PROJECT_VERSION - sets CFBundleVersion (e.g. 42)
#
# Example:
#   MARKETING_VERSION=1.2.3 CURRENT_PROJECT_VERSION=42 ./build.sh universal
#
# Outputs:
#   build/Release-arm64/vision-api-server
#   build/Release-x86_64/vision-api-server
#   build/Release-universal/vision-api-server
#
set -euo pipefail

cd "$(dirname "$0")"

build_one() {
    local variant="$1"   # arm64 | x86_64 | universal
    local archs
    case "$variant" in
        arm64)     archs="arm64" ;;
        x86_64)    archs="x86_64" ;;
        universal) archs="arm64 x86_64" ;;
        *) echo "error: unknown variant '$variant'" >&2; exit 2 ;;
    esac

    local symroot="./build/${variant}"
    rm -rf "$symroot"

    local args=(
        -project VisionApiServer.xcodeproj
        -scheme VisionApiServer
        -configuration Release
        build
        SYMROOT="$symroot"
        ARCHS="$archs"
        ONLY_ACTIVE_ARCH=NO
    )
    if [[ -n "${MARKETING_VERSION:-}" ]]; then
        args+=("MARKETING_VERSION=${MARKETING_VERSION}")
    fi
    if [[ -n "${CURRENT_PROJECT_VERSION:-}" ]]; then
        args+=("CURRENT_PROJECT_VERSION=${CURRENT_PROJECT_VERSION}")
    fi

    echo "==> Building $variant ($archs)"
    xcodebuild "${args[@]}"

    # Flatten: build/<variant>/vision-api-server -> points to Release/vision-api-server
    local binary="${symroot}/Release/vision-api-server"
    if [[ ! -x "$binary" ]]; then
        echo "error: expected binary not found at $binary" >&2
        exit 1
    fi
    echo "    -> $binary"
    lipo -info "$binary" || true
}

variant="${1:-all}"
case "$variant" in
    all)
        build_one arm64
        build_one x86_64
        build_one universal
        ;;
    arm64|x86_64|universal)
        build_one "$variant"
        ;;
    *)
        echo "usage: $0 [arm64|x86_64|universal|all]" >&2
        exit 2
        ;;
esac
