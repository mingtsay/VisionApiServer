#!/usr/bin/env bash
#
# Build VisionApiServer for Release.
#
# Version overrides for CI/CD:
#   MARKETING_VERSION       - sets CFBundleShortVersionString (e.g. 1.2.3)
#   CURRENT_PROJECT_VERSION - sets CFBundleVersion (e.g. 42)
#
# Either set them in the environment or pass as arguments:
#   ./build.sh 1.2.3 42
#   MARKETING_VERSION=1.2.3 CURRENT_PROJECT_VERSION=42 ./build.sh
#
set -euo pipefail

if [[ $# -ge 1 ]]; then MARKETING_VERSION="$1"; fi
if [[ $# -ge 2 ]]; then CURRENT_PROJECT_VERSION="$2"; fi

xcodebuild_args=(
    -project VisionApiServer.xcodeproj
    -scheme VisionApiServer
    -configuration Release
    build
    SYMROOT=./build
)

if [[ -n "${MARKETING_VERSION:-}" ]]; then
    xcodebuild_args+=("MARKETING_VERSION=${MARKETING_VERSION}")
fi
if [[ -n "${CURRENT_PROJECT_VERSION:-}" ]]; then
    xcodebuild_args+=("CURRENT_PROJECT_VERSION=${CURRENT_PROJECT_VERSION}")
fi

xcodebuild "${xcodebuild_args[@]}"
