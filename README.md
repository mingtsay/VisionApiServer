# VisionApiServer

A tiny HTTP server that exposes Apple's **Vision** OCR (`RecognizeTextRequest`) as a local JSON API on macOS. Written in Swift, no third-party dependencies — just `Foundation`, `Vision`, and `Network.framework`.

Primarily intended to be run as a local background service so other tools on the machine can POST images and get recognized text back.

## Requirements

- macOS 15.0 or newer (the Vision `RecognizeTextRequest` API used here is only available on macOS 15+)
- Xcode 16+ to build

## Build

```sh
./build.sh                 # build all three: arm64, x86_64, universal
./build.sh arm64           # arm64 only
./build.sh x86_64          # x86_64 only
./build.sh universal       # universal (arm64 + x86_64)
```

Binaries are written to:

- `build/arm64/Release/vision-api-server`
- `build/x86_64/Release/vision-api-server`
- `build/universal/Release/vision-api-server`

To override the version at build time (useful for CI/CD):

```sh
MARKETING_VERSION=1.2.3 CURRENT_PROJECT_VERSION=42 ./build.sh universal
```

`MARKETING_VERSION` maps to `CFBundleShortVersionString` and `CURRENT_PROJECT_VERSION` maps to `CFBundleVersion`. Both are embedded into the binary and exposed through `/health` and `--help`.

## Run

```sh
./build/universal/Release/vision-api-server                      # defaults: ::1:8765
./build/universal/Release/vision-api-server --host 127.0.0.1 --port 9000
./build/universal/Release/vision-api-server --help
```

| Option | Default | Description |
|---|---|---|
| `-h`, `--host <addr>` | `::1` | Bind address |
| `-p`, `--port <port>` | `8765` | Listen port |
| `--help` | | Show help |

## Install as a launchd service

The binary can install itself as a launchd service so it starts automatically and is restarted on crash.

```sh
# Per-user (no sudo, ~/Library/LaunchAgents)
./vision-api-server --install-user
./vision-api-server --install-user --host 127.0.0.1 --port 9000
./vision-api-server --uninstall-user

# System-wide (requires sudo, /Library/LaunchDaemons)
sudo ./vision-api-server --install
sudo ./vision-api-server --uninstall
```

The plist points at the exact binary path you ran `--install` from, so move or replace the binary before reinstalling. Logs go to `/tmp/vision-api-server.log` and `/tmp/vision-api-server.err`.

## HTTP API

All responses are `application/json; charset=utf-8`.

### `GET /health`

Returns server status, build info, uptime, memory, load average, supported formats, and request counters.

```json
{
  "status": "ok",
  "version": "1.0.0",
  "build_number": "1",
  "build_date": "2026-04-14T03:36:14Z",
  "uptime_seconds": 42,
  "memory_mb": 18.3,
  "load_average": {"1m": 1.2, "5m": 1.1, "15m": 0.9},
  "supported_formats": ["heic", "jpeg", "jpg", "png"],
  "counters": {
    "total_requests": 10,
    "success_count": 9,
    "error_count": 1,
    "active_requests": 0
  }
}
```

### `POST /recognize`

JSON body with either a local file path or base64-encoded image bytes.

```sh
curl -s http://localhost:8765/recognize \
  -H 'Content-Type: application/json' \
  -d '{"path": "/absolute/path/to/image.png"}'

curl -s http://localhost:8765/recognize \
  -H 'Content-Type: application/json' \
  -d "{\"base64\": \"$(base64 -i image.png)\"}"
```

### `POST /recognize/raw`

Raw image bytes as the request body — useful to skip base64 overhead.

```sh
curl -s --data-binary @image.png http://localhost:8765/recognize/raw
```

### Response shape

All recognize endpoints return:

```json
{
  "text": "full recognized text, lines joined with \\n",
  "lines": ["line 1", "line 2"],
  "confidence": 0.9873,
  "paragraph_count": 2,
  "line_count": 2,
  "sufficient": true
}
```

`sufficient` is `true` when `confidence > 0.85` and at least one line was recognized. Paragraphs are detected from vertical gaps between text bounding boxes.

### Error responses

| Status | When |
|---|---|
| 400 | Malformed request (bad JSON, missing fields, invalid base64, incomplete body) |
| 404 | File path does not exist, or unknown route |
| 422 | Unsupported image format (only PNG, JPEG, HEIC recognized by magic-byte sniffing) |
| 500 | Vision or I/O error |

## Supported formats

PNG, JPEG, HEIC. Format is detected by magic bytes on uploaded data, not just by file extension.

## Recognition settings

- Recognition level: `.accurate`
- Language correction: on
- Languages: Traditional Chinese, Simplified Chinese, English (in that priority order)

Edit `makeTextRequest()` in `VisionApiServer/main.swift` to change these.

## Concurrency

Up to 3 OCR operations run in parallel (`maxConcurrentOCR` in `main.swift`). Additional requests queue on an `OCRLimiter` actor so the server stays responsive under load without oversubscribing the CPU/GPU.

Each TCP connection has a 30-second timeout.
