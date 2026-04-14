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

// MARK: - CLI Arguments

func printHelp() {
    let name = (CommandLine.arguments.first as? NSString)?.lastPathComponent ?? "VisionApiServer"
    print("""
    \(name) v\(buildVersion)\(buildNumber.isEmpty ? "" : " (\(buildNumber))") (built \(buildDate))
    Vision OCR HTTP API Server — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)

    USAGE:
      \(name) [OPTIONS]

    OPTIONS:
      -h, --host <addr>   Bind address (default: ::1)
      -p, --port <port>   Listen port (default: 8765)
      --help              Show this help message

    ENDPOINTS:
      GET  /health            Health check
      POST /recognize         JSON body: {"path": "/file"} or {"base64": "..."}
      POST /recognize/raw     Raw image bytes as body

    SUPPORTED FORMATS:
      \(supportedExtensions.sorted().joined(separator: ", "))
    """)
}

func parseArgs() -> (host: String, port: UInt16) {
    var host = "::1"
    var port: UInt16 = 8765
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
        default:
            if arg.hasPrefix("--host=") {
                host = String(arg.dropFirst("--host=".count))
            } else if arg.hasPrefix("--port="), let p = UInt16(arg.dropFirst("--port=".count)) {
                port = p
            }
        }
    }
    return (host, port)
}

// MARK: - HTTP Server

let (host, port) = parseArgs()

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
        return jsonResponse(status: 200, statusText: "OK", ["status": "ok"])
    }

    if method == "POST" && path == "/recognize" {
        guard let body = body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return jsonResponse(status: 400, statusText: "Bad Request", ["error": "invalid request body, expected JSON with 'path' or 'base64' field"])
        }

        do {
            let result: [String: Any]

            if let filePath = json["path"] as? String {
                result = try await recognizeText(at: filePath)
            } else if let base64String = json["base64"] as? String {
                guard let imageData = Data(base64Encoded: base64String) else {
                    return jsonResponse(status: 400, statusText: "Bad Request", ["error": "invalid base64 data"])
                }
                guard isValidImageData(imageData) else {
                    return jsonResponse(status: 422, statusText: "Unprocessable Entity", ["error": "unsupported format"])
                }
                result = try await recognizeText(from: imageData)
            } else {
                return jsonResponse(status: 400, statusText: "Bad Request", ["error": "expected 'path' or 'base64' field"])
            }

            if let status = result["_status"] as? Int,
               let statusText = result["_statusText"] as? String {
                var errorResult = result
                errorResult.removeValue(forKey: "_status")
                errorResult.removeValue(forKey: "_statusText")
                return jsonResponse(status: status, statusText: statusText, errorResult)
            }
            return jsonResponse(status: 200, statusText: "OK", result)
        } catch {
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

        do {
            let result = try await recognizeText(from: imageData)
            return jsonResponse(status: 200, statusText: "OK", result)
        } catch {
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
