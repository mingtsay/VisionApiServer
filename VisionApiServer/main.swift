//
//  main.swift
//  VisionApiServer
//
//  Created by 蔡璨名 on 2026/4/14.
//

import Foundation
import Vision
import Network

// MARK: - Build Info

let buildVersion: String = {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
}()
let buildNumber: String = {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
}()
let buildDate: String = {
    if let execURL = Bundle.main.executableURL,
       let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
       let date = attrs[.modificationDate] as? Date {
        return date.formatted(.iso8601)
    }
    return "unknown"
}()
let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]

// MARK: - Launchd Service Management

let serviceLabel = Bundle.main.bundleIdentifier ?? "tw.mingtsay.app.macos.VisionApiServer"

func executablePath() -> String {
    // _NSGetExecutablePath gives the real path of the running binary
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    var size = UInt32(buffer.count)
    if _NSGetExecutablePath(&buffer, &size) == 0,
       let resolved = realpath(buffer, nil) {
        let path = String(cString: resolved)
        free(resolved)
        return path
    }
    // Fallback: resolve argv[0] via PATH
    let argv0 = CommandLine.arguments.first ?? "vision-api-server"
    return URL(fileURLWithPath: argv0).standardizedFileURL.path
}

func generatePlist(host: String, port: UInt16) -> String {
    let execPath = executablePath()
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>\(serviceLabel)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(execPath)</string>
            <string>--host</string>
            <string>\(host)</string>
            <string>--port</string>
            <string>\(port)</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardOutPath</key>
        <string>/tmp/vision-api-server.log</string>
        <key>StandardErrorPath</key>
        <string>/tmp/vision-api-server.err</string>
    </dict>
    </plist>
    """
}

enum ServiceScope {
    case system  // /Library/LaunchDaemons (requires root)
    case user    // ~/Library/LaunchAgents

    var plistPath: String {
        switch self {
        case .system:
            return "/Library/LaunchDaemons/\(serviceLabel).plist"
        case .user:
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return "\(home)/Library/LaunchAgents/\(serviceLabel).plist"
        }
    }

    var displayName: String {
        switch self {
        case .system: return "system"
        case .user: return "user"
        }
    }

    var domain: String {
        switch self {
        case .system: return "system"
        case .user: return "gui/\(getuid())"
        }
    }
}

func installService(scope: ServiceScope, host: String, port: UInt16) {
    let plistPath = scope.plistPath
    let plistDir = (plistPath as NSString).deletingLastPathComponent

    // Ensure directory exists for user scope
    if scope == .user {
        try? FileManager.default.createDirectory(atPath: plistDir, withIntermediateDirectories: true)
    }

    let plist = generatePlist(host: host, port: port)
    do {
        try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
    } catch {
        fputs("Error: failed to write plist to \(plistPath): \(error.localizedDescription)\n", stderr)
        if scope == .system {
            fputs("Hint: system scope requires sudo.\n", stderr)
        }
        exit(1)
    }

    // Bootstrap the service
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["bootstrap", scope.domain, plistPath]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fputs("Error: failed to run launchctl: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    if process.terminationStatus == 0 {
        print("Installed and started \(scope.displayName) service.")
        print("  Plist: \(plistPath)")
        print("  Binary: \(executablePath())")
        print("  Listen: \(formatListenAddress(host: host, port: port))")
        print("  Logs: /tmp/vision-api-server.log")
    } else {
        // Service may already be loaded — try kickstart instead
        fputs("Warning: bootstrap returned \(process.terminationStatus) (service may already be loaded).\n", stderr)
        fputs("Try: launchctl kickstart -k \(scope.domain)/\(serviceLabel)\n", stderr)
        exit(1)
    }
    exit(0)
}

func uninstallService(scope: ServiceScope) {
    let plistPath = scope.plistPath

    // Bootout the service
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["bootout", "\(scope.domain)/\(serviceLabel)"]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fputs("Error: failed to run launchctl: \(error.localizedDescription)\n", stderr)
    }

    // Remove plist
    if FileManager.default.fileExists(atPath: plistPath) {
        do {
            try FileManager.default.removeItem(atPath: plistPath)
            print("Removed \(plistPath)")
        } catch {
            fputs("Error: failed to remove plist: \(error.localizedDescription)\n", stderr)
            if scope == .system {
                fputs("Hint: system scope requires sudo.\n", stderr)
            }
            exit(1)
        }
    }

    print("Uninstalled \(scope.displayName) service.")
    exit(0)
}

// MARK: - CLI Arguments

func printHelp() {
    let name = (CommandLine.arguments.first as? NSString)?.lastPathComponent ?? "VisionApiServer"
    print("""
    \(name) v\(buildVersion)\(buildNumber.isEmpty ? "" : " (\(buildNumber))") (built \(buildDate))
    Vision OCR HTTP API Server — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)

    USAGE:
      \(name) [OPTIONS]

    OPTIONS:
      -h, --host <addr>      Bind address (default: ::1)
      -p, --port <port>      Listen port (default: 8765)
      --help                 Show this help message

    SERVICE MANAGEMENT:
      --install              Install as system launchd service (requires sudo)
      --uninstall            Uninstall system launchd service (requires sudo)
      --install-user         Install as user launchd service
      --uninstall-user       Uninstall user launchd service

    ENDPOINTS:
      GET  /health            Health check
      POST /recognize         JSON body: {"path": "/file"} or {"base64": "..."}
      POST /recognize/raw     Raw image bytes as body

    SUPPORTED FORMATS:
      \(supportedExtensions.sorted().joined(separator: ", "))
    """)
}

enum Action {
    case run
    case install(ServiceScope)
    case uninstall(ServiceScope)
}

func parseArgs() -> (action: Action, host: String, port: UInt16) {
    var host = "::1"
    var port: UInt16 = 8765
    var action: Action = .run
    var args = CommandLine.arguments.dropFirst().makeIterator()

    while let arg = args.next() {
        switch arg {
        case "--help":
            printHelp()
            exit(0)
        case "-h", "--host":
            if let val = args.next() { host = val }
        case "-p", "--port":
            if let val = args.next(), let p = UInt16(val) { port = p }
        case "--install":
            action = .install(.system)
        case "--uninstall":
            action = .uninstall(.system)
        case "--install-user":
            action = .install(.user)
        case "--uninstall-user":
            action = .uninstall(.user)
        default:
            if arg.hasPrefix("--host=") {
                host = String(arg.dropFirst("--host=".count))
            } else if arg.hasPrefix("--port="), let p = UInt16(arg.dropFirst("--port=".count)) {
                port = p
            }
        }
    }
    return (action, host, port)
}

// MARK: - HTTP Server

let (action, host, port) = parseArgs()

// Handle install/uninstall before starting the server
switch action {
case .install(let scope):
    installService(scope: scope, host: host, port: port)
case .uninstall(let scope):
    uninstallService(scope: scope)
case .run:
    break
}

func formatListenAddress(host: String, port: UInt16) -> String {
    if host.contains(":") {
        return "http://[\(host)]:\(port)"
    }
    return "http://\(host):\(port)"
}

func jsonData(_ dict: [String: Any]) -> Data {
    do {
        return try JSONSerialization.data(withJSONObject: dict)
    } catch {
        return #"{"error":"internal serialization error"}"#.data(using: .utf8)!
    }
}

func httpResponse(status: Int, statusText: String, body: Data) -> Data {
    let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    return header.data(using: .utf8)! + body
}

func jsonResponse(status: Int, statusText: String, _ dict: [String: Any]) -> Data {
    httpResponse(status: status, statusText: statusText, body: jsonData(dict))
}

// MARK: - Request Counters

let serverStartDate = Date()

actor RequestCounters {
    private(set) var totalRequests: Int = 0
    private(set) var successCount: Int = 0
    private(set) var errorCount: Int = 0
    private(set) var activeRequests: Int = 0

    func beginRequest() { totalRequests += 1; activeRequests += 1 }
    func endSuccess() { successCount += 1; activeRequests -= 1 }
    func endError() { errorCount += 1; activeRequests -= 1 }

    func snapshot() -> [String: Int] {
        [
            "total_requests": totalRequests,
            "success_count": successCount,
            "error_count": errorCount,
            "active_requests": activeRequests
        ]
    }
}

let counters = RequestCounters()

// MARK: - System Info

func memoryUsageMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return -1 }
    return Double(info.resident_size) / (1024 * 1024)
}

func systemLoadAverage() -> [Double] {
    var loadavg = [Double](repeating: 0, count: 3)
    getloadavg(&loadavg, 3)
    return loadavg
}

// MARK: - Concurrency Control

/// Limits parallel OCR operations to avoid CPU/memory pressure
let maxConcurrentOCR = 3

actor OCRLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.available = limit }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            available += 1
        }
    }
}

let ocrLimiter = OCRLimiter(limit: maxConcurrentOCR)

func withOCRSlot<T>(_ work: () async throws -> T) async throws -> T {
    await ocrLimiter.acquire()
    do {
        let result = try await work()
        await ocrLimiter.release()
        return result
    } catch {
        await ocrLimiter.release()
        throw error
    }
}

// MARK: - Image Validation

let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])
let jpegSignature = Data([0xFF, 0xD8, 0xFF])
let heicSignatures: [Data] = [
    Data("ftypheic".utf8),
    Data("ftypheix".utf8),
    Data("ftypmif1".utf8)
]

func isValidImageData(_ data: Data) -> Bool {
    if data.count < 12 { return false }
    if data.prefix(4) == pngSignature { return true }
    if data.prefix(3) == jpegSignature { return true }
    // HEIC: ftyp box starts at byte 4
    let ftypSlice = data[4..<min(12, data.count)]
    for sig in heicSignatures {
        if ftypSlice.starts(with: sig) { return true }
    }
    return false
}

// MARK: - Vision OCR

func makeTextRequest() -> RecognizeTextRequest {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = [
        Locale.Language(identifier: "zh-Hant"),
        Locale.Language(identifier: "zh-Hans"),
        Locale.Language(identifier: "en-US")
    ]
    return request
}

func buildResult(from observations: [RecognizedTextObservation]) -> [String: Any] {
    var lines: [String] = []
    var totalConfidence: Float = 0
    var candidateCount = 0

    // Use bounding box Y gaps to detect paragraph breaks.
    // Vision's coordinate origin is at the bottom-left; observations are ordered top-to-bottom,
    // so each successive line has a *smaller* Y value. We compare the previous line's minY
    // (its bottom edge) against the current line's maxY (its top edge).
    var paragraphCount = 0
    var lastMinY: CGFloat = -1
    let gapThreshold: CGFloat = 0.02 // normalized coordinate threshold

    for observation in observations {
        let candidates = observation.topCandidates(1)
        if let top = candidates.first {
            lines.append(top.string)
            totalConfidence += top.confidence
            candidateCount += 1
        }

        let box = observation.boundingBox.cgRect
        if lastMinY < 0 {
            paragraphCount = 1
        } else if (lastMinY - box.maxY) > gapThreshold {
            paragraphCount += 1
        }
        lastMinY = box.minY
    }

    let fullText = lines.joined(separator: "\n")
    let avgConfidence = candidateCount > 0 ? totalConfidence / Float(candidateCount) : 0
    let confidence = Double((avgConfidence * 10000).rounded() / 10000)
    let sufficient = confidence > 0.85 && !lines.isEmpty

    return [
        "text": fullText,
        "lines": lines,
        "confidence": confidence,
        "paragraph_count": paragraphCount,
        "line_count": lines.count,
        "sufficient": sufficient
    ]
}

func recognizeText(from imageData: Data) async throws -> [String: Any] {
    try await withOCRSlot {
        let request = makeTextRequest()
        let observations = try await request.perform(on: imageData)
        return buildResult(from: observations)
    }
}

func recognizeText(at path: String) async throws -> [String: Any] {
    let url = URL(fileURLWithPath: path)

    guard FileManager.default.fileExists(atPath: path) else {
        return ["_status": 404, "_statusText": "Not Found", "error": "file not found"]
    }

    let ext = url.pathExtension.lowercased()
    guard supportedExtensions.contains(ext) else {
        return ["_status": 422, "_statusText": "Unprocessable Entity", "error": "unsupported format"]
    }

    // Use perform(on: URL) to let Vision handle memory mapping internally
    return try await withOCRSlot {
        let request = makeTextRequest()
        let observations = try await request.perform(on: url)
        return buildResult(from: observations)
    }
}

// MARK: - Request Handling

let headerBodySeparator = Data("\r\n\r\n".utf8)

func parseHTTPRequest(_ data: Data) -> (method: String, path: String, body: Data?) {
    // Find the header/body boundary by searching in raw Data to preserve binary body
    guard let separatorRange = data.range(of: headerBodySeparator) else {
        return ("", "", nil)
    }

    let headerData = data[data.startIndex..<separatorRange.lowerBound]
    guard let headerSection = String(data: headerData, encoding: .utf8) else {
        return ("", "", nil)
    }

    let bodyData: Data? = separatorRange.upperBound < data.endIndex
        ? data[separatorRange.upperBound...]
        : nil

    let firstLine = headerSection.components(separatedBy: "\r\n").first ?? ""
    let tokens = firstLine.split(separator: " ")
    guard tokens.count >= 2 else { return ("", "", nil) }

    return (String(tokens[0]), String(tokens[1]), bodyData)
}

func handleRequest(_ data: Data) async -> Data {
    let (method, path, body) = parseHTTPRequest(data)

    if method == "GET" && path == "/health" {
        let uptime = Date().timeIntervalSince(serverStartDate)
        let load = systemLoadAverage()
        let stats = await counters.snapshot()
        let health: [String: Any] = [
            "status": "ok",
            "version": buildVersion,
            "build_number": buildNumber,
            "build_date": buildDate,
            "uptime_seconds": Int(uptime),
            "memory_mb": Double(round(memoryUsageMB() * 100) / 100),
            "load_average": ["1m": load[0], "5m": load[1], "15m": load[2]],
            "supported_formats": supportedExtensions.sorted(),
            "counters": stats
        ]
        return jsonResponse(status: 200, statusText: "OK", health)
    }

    if method == "POST" && path == "/recognize" {
        guard let body = body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return jsonResponse(status: 400, statusText: "Bad Request", ["error": "invalid request body, expected JSON with 'path' or 'base64' field"])
        }

        await counters.beginRequest()
        do {
            let result: [String: Any]

            if let filePath = json["path"] as? String {
                result = try await recognizeText(at: filePath)
            } else if let base64String = json["base64"] as? String {
                guard let imageData = Data(base64Encoded: base64String) else {
                    await counters.endError()
                    return jsonResponse(status: 400, statusText: "Bad Request", ["error": "invalid base64 data"])
                }
                guard isValidImageData(imageData) else {
                    await counters.endError()
                    return jsonResponse(status: 422, statusText: "Unprocessable Entity", ["error": "unsupported format"])
                }
                result = try await recognizeText(from: imageData)
            } else {
                await counters.endError()
                return jsonResponse(status: 400, statusText: "Bad Request", ["error": "expected 'path' or 'base64' field"])
            }

            if let status = result["_status"] as? Int,
               let statusText = result["_statusText"] as? String {
                var errorResult = result
                errorResult.removeValue(forKey: "_status")
                errorResult.removeValue(forKey: "_statusText")
                await counters.endError()
                return jsonResponse(status: status, statusText: statusText, errorResult)
            }
            await counters.endSuccess()
            return jsonResponse(status: 200, statusText: "OK", result)
        } catch {
            await counters.endError()
            return jsonResponse(status: 500, statusText: "Internal Server Error", ["error": error.localizedDescription])
        }
    }

    if method == "POST" && path == "/recognize/raw" {
        guard let body = body, !body.isEmpty else {
            return jsonResponse(status: 400, statusText: "Bad Request", ["error": "empty body, expected raw image data"])
        }

        let imageData = Data(body)
        guard isValidImageData(imageData) else {
            return jsonResponse(status: 422, statusText: "Unprocessable Entity", ["error": "unsupported format"])
        }

        await counters.beginRequest()
        do {
            let result = try await recognizeText(from: imageData)
            await counters.endSuccess()
            return jsonResponse(status: 200, statusText: "OK", result)
        } catch {
            await counters.endError()
            return jsonResponse(status: 500, statusText: "Internal Server Error", ["error": error.localizedDescription])
        }
    }

    return jsonResponse(status: 404, statusText: "Not Found", ["error": "not found"])
}

// MARK: - TCP Server with Network.framework

let listener: NWListener
do {
    let params = NWParameters.tcp
    listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
} catch {
    fatalError("Failed to create listener: \(error)")
}

func sendResponse(_ response: Data, on connection: NWConnection) {
    connection.send(content: response, completion: .contentProcessed { _ in
        connection.cancel()
    })
}

func receiveFullRequest(on connection: NWConnection, accumulated: Data = Data()) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
        guard let data = data, error == nil else {
            connection.cancel()
            return
        }

        let buffer = accumulated + data

        // Check if we have the full HTTP request by searching for header/body boundary in raw Data
        if let separatorRange = buffer.range(of: headerBodySeparator) {
            let headerData = buffer[buffer.startIndex..<separatorRange.lowerBound]
            let bodyStart = separatorRange.upperBound

            // Parse Content-Length from headers
            var contentLength = 0
            if let headerStr = String(data: headerData, encoding: .utf8) {
                for line in headerStr.split(separator: "\r\n") {
                    if line.lowercased().hasPrefix("content-length:") {
                        let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                        contentLength = Int(value) ?? 0
                    }
                }
            }

            let bodyReceived = buffer.count - bodyStart
            if bodyReceived >= contentLength {
                Task {
                    guard !Task.isCancelled else { connection.cancel(); return }
                    let response = await handleRequest(buffer)
                    sendResponse(response, on: connection)
                }
                return
            }
        }

        if isComplete {
            // Connection closed before full body received — likely client disconnect
            Task {
                guard !Task.isCancelled else { connection.cancel(); return }
                let response = jsonResponse(status: 400, statusText: "Bad Request",
                                            ["error": "incomplete request body"])
                sendResponse(response, on: connection)
            }
        } else {
            receiveFullRequest(on: connection, accumulated: buffer)
        }
    }
}

let requestTimeout: TimeInterval = 30

listener.newConnectionHandler = { connection in
    connection.start(queue: .global())

    // Timeout: cancel connection if request takes too long
    let deadline = DispatchTime.now() + requestTimeout
    DispatchQueue.global().asyncAfter(deadline: deadline) { [weak connection] in
        if let c = connection, c.state != .cancelled {
            c.cancel()
        }
    }

    receiveFullRequest(on: connection)
}

listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
        print("Vision OCR API Server listening on \(formatListenAddress(host: host, port: port))")
    case .failed(let error):
        fatalError("Listener failed: \(error)")
    default:
        break
    }
}

listener.start(queue: .main)
RunLoop.main.run()
