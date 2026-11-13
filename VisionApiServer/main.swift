import Foundation
import Network
import Vision
import CoreGraphics
import ImageIO

// MARK: - Version

let kVersion = "1.1.0"
let kBuildDate: String = {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    df.timeZone = TimeZone(identifier: "UTC")
    return df.string(from: Date())
}()
let kBuildNumber: String = {
    let df = DateFormatter()
    df.dateFormat = "yyMMddHH"
    df.timeZone = TimeZone(identifier: "UTC")
    return df.string(from: Date())
}()

// MARK: - Request Counters

final class RequestCounters: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tw.mingtsay.vision-api-server.counters")
    private var _total: Int = 0
    private var _success: Int = 0
    private var _error: Int = 0
    private var _active: Int = 0

    var total: Int { queue.sync { _total } }
    var success: Int { queue.sync { _success } }
    var errorCount: Int { queue.sync { _error } }
    var active: Int { queue.sync { _active } }

    func begin() { queue.sync { _total += 1; _active += 1 } }
    func end(ok: Bool) {
        queue.sync {
            _active -= 1
            if ok { _success += 1 } else { _error += 1 }
        }
    }
}

// MARK: - OCR Limiter

final class OCRLimiter: @unchecked Sendable {
    private let sem: DispatchSemaphore

    init(maxConcurrent: Int = 4) {
        sem = DispatchSemaphore(value: maxConcurrent)
    }

    func acquire(timeout: TimeInterval = 30) -> Bool {
        sem.wait(timeout: .now() + timeout) == .success
    }

    func release() { sem.signal() }
}

// MARK: - OCR Engine

struct OCRObservation {
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct OCRResult {
    let text: String
    let lines: [String]
    let paragraphCount: Int
    let confidence: Float
    let observations: [OCRObservation]?
}

func performOCR(imageData: Data, languages: [String]?, includeBoxes: Bool) -> OCRResult {
    guard let src = CGImageSourceCreateWithData(imageData as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        return OCRResult(text: "", lines: [], paragraphCount: 0, confidence: 0,
                         observations: includeBoxes ? [] : nil)
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if let langs = languages, !langs.isEmpty {
        request.recognitionLanguages = langs
    } else {
        request.recognitionLanguages = ["zh-Hant-TW", "ja-JP", "en-US", "zh-Hant-HK", "zh-Hans-CN"]
    }

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do { try handler.perform([request]) } catch { /* fall through to empty results */ }

    guard let results = request.results, !results.isEmpty else {
        return OCRResult(text: "", lines: [], paragraphCount: 0, confidence: 0,
                         observations: includeBoxes ? [] : nil)
    }

    // Sort top-to-bottom (descending normalised Y), then left-to-right
    let sorted = results.sorted { a, b in
        let ay = a.boundingBox.origin.y + a.boundingBox.height
        let by = b.boundingBox.origin.y + b.boundingBox.height
        if abs(ay - by) > 0.01 { return ay > by }
        return a.boundingBox.origin.x < b.boundingBox.origin.x
    }

    var lines: [String] = []
    var totalConf: Float = 0
    var obs: [OCRObservation] = []

    for r in sorted {
        guard let c = r.topCandidates(1).first else { continue }
        lines.append(c.string)
        totalConf += c.confidence
        if includeBoxes {
            let b = r.boundingBox
            obs.append(OCRObservation(
                text: c.string, confidence: c.confidence,
                x: b.origin.x, y: b.origin.y,
                width: b.size.width, height: b.size.height))
        }
    }

    let avgConf = Float(totalConf) / Float(sorted.count)

    // Paragraph detection: a vertical gap > 1.5× line height starts a new paragraph
    var paraCount = lines.isEmpty ? 0 : 1
    if sorted.count > 1 {
        for i in 1..<sorted.count {
            let prevBottom = sorted[i - 1].boundingBox.origin.y
            let currTop = sorted[i].boundingBox.origin.y + sorted[i].boundingBox.height
            let gap = prevBottom - currTop
            let lh = sorted[i].boundingBox.height
            if lh > 0 && gap > lh * 1.5 { paraCount += 1 }
        }
    }

    return OCRResult(
        text: lines.joined(separator: "\n"),
        lines: lines,
        paragraphCount: paraCount,
        confidence: avgConf,
        observations: includeBoxes ? obs : nil)
}

// MARK: - Image Validation

func isValidImageData(_ data: Data) -> Bool {
    guard data.count >= 4 else { return false }
    let bytes = [UInt8](data.prefix(12))
    // PNG: 89 50 4E 47
    if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 { return true }
    // JPEG: FF D8 FF
    if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF { return true }
    // HEIC: offset 4 = "ftyp"
    if data.count >= 12 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 { return true }
    return false
}

// MARK: - JSON Helpers

func jsonData(_ obj: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
}

// MARK: - HTTP Response

struct HTTPResponse {
    let status: Int
    let body: Data
    let contentType: String

    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: jsonData(obj),
                     contentType: "application/json; charset=utf-8")
    }

    static func error(_ msg: String, status: Int = 400) -> HTTPResponse {
        json(["error": msg], status: status)
    }

    func serialized() -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 429: reason = "Too Many Requests"
        case 500: reason = "Internal Server Error"
        default:  reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var d = Data(head.utf8)
        d.append(body)
        return d
    }
}

// MARK: - HTTP Request Parser

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

func parseHTTP(_ data: Data) -> HTTPRequest? {
    guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    guard let hdr = String(data: data[data.startIndex..<sep.lowerBound], encoding: .utf8) else { return nil }
    let lines = hdr.split(separator: "\r\n", maxSplits: 500, omittingEmptySubsequences: false)
    guard let first = lines.first else { return nil }
    let parts = first.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2 else { return nil }

    var headers: [String: String] = [:]
    for i in 1..<lines.count {
        guard let colon = lines[i].firstIndex(of: ":") else { continue }
        let k = String(lines[i][lines[i].startIndex..<colon]).lowercased()
        let v = String(lines[i][lines[i].index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        headers[k] = v
    }

    return HTTPRequest(method: String(parts[0]), path: String(parts[1]),
                       headers: headers, body: Data(data[sep.upperBound...]))
}

// MARK: - Router

let counters = RequestCounters()
let limiter = OCRLimiter(maxConcurrent: 3)
let startTime = Date()

func route(_ req: HTTPRequest) -> HTTPResponse {
    switch (req.method, req.path) {
    case ("GET", "/health"):
        return health()
    case ("POST", "/recognize"):
        return recognize(req)
    case ("POST", "/recognize/raw"):
        return recognizeRaw(req)
    default:
        return HTTPResponse.error(
            "VisionApiServer v\(kVersion)\n" +
            "  GET  /health            Health check\n" +
            "  POST /recognize         JSON body: {\"path\": \"/file\"} or {\"base64\": \"...\"}\n" +
            "  POST /recognize/raw     Raw image bytes as body",
            status: 404)
    }
}

func health() -> HTTPResponse {
    let uptime = Int(Date().timeIntervalSince(startTime))

    var loadavg = [Double](repeating: 0, count: 3)
    getloadavg(&loadavg, 3)

    // Resident memory via task_info
    var memMB = 0.0
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: Int(count)) { reboundPtr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPtr, &count)
        }
    }
    if kr == KERN_SUCCESS { memMB = Double(info.resident_size) / 1_048_576.0 }

    return .json([
        "status": "ok",
        "version": kVersion,
        "build_number": kBuildNumber,
        "build_date": kBuildDate,
        "uptime_seconds": uptime,
        "memory_mb": (memMB * 10).rounded() / 10,
        "supported_formats": ["heic", "jpeg", "jpg", "png"],
        "load_average": ["1m": loadavg[0], "5m": loadavg[1], "15m": loadavg[2]],
        "counters": [
            "total_requests": counters.total,
            "success_count": counters.success,
            "error_count": counters.errorCount,
            "active_requests": counters.active,
        ],
    ] as [String: Any])
}

func recognize(_ req: HTTPRequest) -> HTTPResponse {
    guard !req.body.isEmpty else {
        return .error("invalid request body, expected JSON with 'path' or 'base64' field")
    }
    guard let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
        return .error("invalid request body, expected JSON with 'path' or 'base64' field")
    }

    let langs = json["languages"] as? [String]
    let includeBoxes = json["include_boxes"] as? Bool ?? false

    let imageData: Data
    if let path = json["path"] as? String {
        guard let d = FileManager.default.contents(atPath: path) else {
            return .error("file not found: \(path)", status: 404)
        }
        imageData = d
    } else if let b64 = json["base64"] as? String {
        guard let d = Data(base64Encoded: b64) else {
            return .error("invalid base64 data")
        }
        imageData = d
    } else {
        return .error("expected 'path' or 'base64' field")
    }

    return doOCR(imageData, langs: langs, includeBoxes: includeBoxes)
}

func recognizeRaw(_ req: HTTPRequest) -> HTTPResponse {
    guard !req.body.isEmpty else {
        return .error("incomplete request body")
    }
    return doOCR(req.body, langs: nil, includeBoxes: false)
}

func doOCR(_ imageData: Data, langs: [String]?, includeBoxes: Bool) -> HTTPResponse {
    guard isValidImageData(imageData) else {
        return .error("unsupported image format (expected PNG, JPEG, or HEIC)", status: 422)
    }
    counters.begin()
    guard limiter.acquire() else {
        counters.end(ok: false)
        return .error("too many concurrent requests, try again later", status: 429)
    }
    defer { limiter.release() }

    let r = performOCR(imageData: imageData, languages: langs, includeBoxes: includeBoxes)
    counters.end(ok: true)

    var dict: [String: Any] = [
        "text": r.text,
        "lines": r.lines,
        "line_count": r.lines.count,
        "paragraph_count": r.paragraphCount,
        "confidence": r.confidence,
        "sufficient": r.confidence > 0.85 && !r.lines.isEmpty,
    ]

    if let obs = r.observations {
        dict["observations"] = obs.map { o -> [String: Any] in
            [
                "text": o.text,
                "confidence": o.confidence,
                "bounding_box": [
                    "x": (o.x * 10000).rounded() / 10000,
                    "y": (o.y * 10000).rounded() / 10000,
                    "width": (o.width * 10000).rounded() / 10000,
                    "height": (o.height * 10000).rounded() / 10000,
                ],
            ]
        }
    }

    return .json(dict)
}

// MARK: - TCP Server

func startServer(host: String, port: UInt16) {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true

    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
        fputs("Invalid port: \(port)\n", stderr)
        exit(1)
    }

    let listener: NWListener
    do { listener = try NWListener(using: params, on: nwPort) }
    catch { fputs("Failed to create listener: \(error)\n", stderr); exit(1) }

    listener.newConnectionHandler = { conn in
        conn.start(queue: .global(qos: .userInitiated))
        handleConnection(conn)
    }

    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            print("VisionApiServer v\(kVersion) listening on \(host):\(port)")
        case .failed(let err):
            fputs("Listener failed: \(err)\n", stderr)
            exit(1)
        default: break
        }
    }

    listener.start(queue: .main)
    signal(SIGTERM, SIG_IGN)
    let termSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termSrc.setEventHandler {
        print("SIGTERM received, shutting down…")
        listener.cancel()
        exit(0)
    }
    termSrc.resume()
    dispatchMain()
}

func handleConnection(_ conn: NWConnection) {
    var buf = Data()

    func recv() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { data, _, isComplete, error in
            if let d = data { buf.append(d) }

            if let sep = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buf[buf.startIndex..<sep.lowerBound]
                var contentLength = 0
                if let hdr = String(data: headerData, encoding: .utf8) {
                    for line in hdr.split(separator: "\r\n") {
                        let lower = line.lowercased()
                        if lower.hasPrefix("content-length:") {
                            contentLength = Int(lower.split(separator: ":").last?
                                .trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
                        }
                    }
                }
                let bodyStart = sep.upperBound
                let bodyLen = buf.distance(from: bodyStart, to: buf.endIndex)
                if bodyLen >= contentLength {
                    respond(conn, buf)
                    return
                }
            }

            // 8 MB safety limit
            if buf.count > 8_388_608 {
                let r = HTTPResponse.error("request too large", status: 413).serialized()
                conn.send(content: r, completion: .contentProcessed { _ in conn.cancel() })
                return
            }

            if isComplete || error != nil {
                if !buf.isEmpty { respond(conn, buf) } else { conn.cancel() }
                return
            }

            recv()
        }
    }

    recv()
}

func respond(_ conn: NWConnection, _ data: Data) {
    let resp: HTTPResponse
    if let req = parseHTTP(data) {
        resp = route(req)
    } else {
        resp = .error("malformed HTTP request")
    }
    conn.send(content: resp.serialized(), completion: .contentProcessed { _ in
        conn.cancel()
    })
}

// MARK: - Entry Point

var host = "::"
var port: UInt16 = 8765

var argv = Array(CommandLine.arguments.dropFirst())
var idx = 0
while idx < argv.count {
    switch argv[idx] {
    case "--host":
        idx += 1; if idx < argv.count { host = argv[idx] }
    case "--port":
        idx += 1; if idx < argv.count { port = UInt16(argv[idx]) ?? 8765 }
    case "--help", "-h":
        print("Usage: vision-api-server [--host HOST] [--port PORT]")
        print("  Default: --host :: --port 8765")
        exit(0)
    default: break
    }
    idx += 1
}

startServer(host: host, port: port)
