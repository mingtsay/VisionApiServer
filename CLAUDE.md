# CLAUDE.md

Guidance for Claude Code working in this repo. Keep it short — if something is already documented elsewhere, point to it instead of restating.

## What this project is

A single-target macOS command-line tool that runs a local HTTP server exposing Apple's Vision `RecognizeTextRequest` as a JSON API. All production code lives in one file: `VisionApiServer/main.swift`. There are no third-party dependencies; the only frameworks used are `Foundation`, `Vision`, and `Network` (for the TCP listener).

See `README.md` for user-facing docs (endpoints, install, run).

## Build and run

- Build: `./build.sh` — writes `build/Release/vision-api-server`.
- Build with version override: `MARKETING_VERSION=1.2.3 CURRENT_PROJECT_VERSION=42 ./build.sh` (also accepts positional args). These flow through xcodebuild into the embedded Info.plist.
- Run: `./build/Release/vision-api-server [--host ::1] [--port 8765]`
- There are no tests — verify changes by running the server and hitting `/health`, `/recognize`, and `/recognize/raw` with `curl`.

## Project conventions

- **One-file layout.** Everything is in `main.swift`, organized by `// MARK: -` sections (Build Info, Launchd Service Management, CLI Arguments, HTTP Server, Request Counters, System Info, Concurrency Control, Image Validation, Vision OCR, Request Handling, TCP Server). Keep adding to the existing sections rather than creating new files unless the file grows unmanageable.
- **No dependencies.** Do not introduce SwiftPM or CocoaPods. HTTP parsing is deliberately minimal and hand-rolled — match that style rather than pulling in a framework.
- **Actors for shared mutable state.** `OCRLimiter` and `RequestCounters` are actors. Any new shared state should be too.
- **Concurrency cap.** `maxConcurrentOCR = 3` bounds Vision parallelism. Don't remove the limiter — Vision OCR is CPU/GPU heavy and unbounded parallelism tanks throughput.
- **Binary format sniffing.** `isValidImageData` checks magic bytes for PNG/JPEG/HEIC. When adding formats, add to both `supportedExtensions` and the sniffer.
- **Error responses** are JSON with an `error` field and appropriate HTTP status (400/404/422/500). The `recognizeText(at:)` path uses `_status`/`_statusText` sentinel keys to pass status codes out of the result dict — keep this pattern if extending that function.

## Versioning

`buildVersion` and `buildNumber` are read from `Bundle.main.infoDictionary` at runtime. For a plain CLI target this only works because the project sets:

- `GENERATE_INFOPLIST_FILE = YES`
- `CREATE_INFOPLIST_SECTION_IN_BINARY = YES` (embeds the plist into `__TEXT,__info_plist`)
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`

If `--help` or `/health` starts showing `vunknown`, one of those settings got dropped.

## Launchd install

`--install` / `--install-user` write a plist that hard-codes the current executable's absolute path. Moving the binary after install breaks the service — reinstall after moving. The service label is the bundle identifier (`tw.mingtsay.app.macos.VisionApiServer`).

## Deployment target

`MACOSX_DEPLOYMENT_TARGET = 15.0`. Do not lower this — `RecognizeTextRequest` (the new async Vision API used throughout) requires macOS 15. The older `VNRecognizeTextRequest` path is not used.

## What to ignore

- `build/` — xcodebuild output, already gitignored.
- `.git/`, `DerivedData/`.
