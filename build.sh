#!/usr/bin/env bash
xcodebuild \
    -project VisionApiServer.xcodeproj \
    -scheme VisionApiServer \
    -configuration Release \
    build \
    SYMROOT=./build
