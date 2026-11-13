# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-11-13

### Added
- **Bounding box support**: `POST /recognize` accepts `"include_boxes": true` in the
  request body. When enabled, the response includes an `observations` array with each
  recognized text line, its confidence, and its normalized bounding box (origin at
  bottom-left, values 0–1).
- Image format validation via magic-byte sniffing (PNG, JPEG, HEIC). Unsupported
  formats now return HTTP 422 instead of an empty OCR result.
- Graceful SIGTERM handling.

### Changed
- Default recognition languages changed to: zh-Hant-TW, ja-JP, en-US, zh-Hant-HK,
  zh-Hans-CN (was zh-Hant, zh-Hans, en-US). Clients can still override via the
  `languages` field in the request body.
- `sufficient` threshold aligned with v1 documentation: `confidence > 0.85`
  (was >= 0.5 in initial v2 development).
- Max concurrent OCR operations: 3 (aligned with v1).
- Rewritten from scratch for `swiftc` command-line builds (no Xcode required).
  Uses `VNRecognizeTextRequest` (available since macOS 10.15) and
  `DispatchQueue`-based concurrency instead of macOS 15 `RecognizeTextRequest`
  and Swift actors. The `build.sh` / xcodebuild path still works.

## [1.0.1] - 2026-04-14

### Fixed
- `executablePath()` now resolves the real path of the running binary via
  `_NSGetExecutablePath` + `realpath`, instead of trusting `argv[0]`. This
  fixes `--install` / `--install-user` writing a launchd plist with a wrong
  or relative executable path when the binary is launched via `PATH` lookup
  or a symlink.

### Changed
- `CURRENT_PROJECT_VERSION` bumped to `26041402`.

## [1.0.0] - 2026-04-14

Initial release.

### Added
- HTTP server exposing Apple's Vision `RecognizeTextRequest` as a local JSON API.
- `GET /health` — status, build info, uptime, memory, load average, request counters.
- `POST /recognize` — JSON body with `path` (local file) or `base64` field.
- `POST /recognize/raw` — raw image bytes as the request body.
- Magic-byte image format detection for PNG, JPEG, and HEIC.
- Recognition languages: Traditional Chinese, Simplified Chinese, English.
- Bounded OCR concurrency (3 parallel operations via an `OCRLimiter` actor).
- 30-second per-connection timeout.
- Self-install as a launchd service: `--install` (system) and `--install-user` (user).
- Versioning via `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` embedded in the
  binary, overridable at build time for CI/CD.

[1.0.1]: https://github.com/mingtsay/VisionApiServer/releases/tag/v1.0.1
[1.0.0]: https://github.com/mingtsay/VisionApiServer/releases/tag/v1.0.0
[2.0.0]: https://github.com/mingtsay/VisionApiServer/releases/tag/v2.0.0
