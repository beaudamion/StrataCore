import Foundation

public struct PerceptualQCResult: Equatable, Sendable {
    public let metric: PerceptualQCMetric
    public let primaryScore: Double
    public let summary: String
    
    public init(metric: PerceptualQCMetric, primaryScore: Double, summary: String) {
        self.metric = metric
        self.primaryScore = primaryScore
        self.summary = summary
    }
}

public enum PerceptualQCRunner {
    /// Builds FFmpeg arguments to score distorted output against reference input using XPSNR or libvmaf.
    public static func buildArguments(
        distortedURL: URL,
        referenceURL: URL,
        metric: PerceptualQCMetric,
        vmafJSONLogURL: URL? = nil
    ) -> [String]? {
        guard metric != .none else { return nil }
        let filterGraph: String
        switch metric {
        case .none:
            return nil
        case .xpsnr:
            filterGraph = "[0:v][1:v]scale2ref[dist][ref];[dist][ref]xpsnr"
        case .libvmaf:
            if let logURL = vmafJSONLogURL {
                let escaped = logURL.path.replacingOccurrences(of: ":", with: "\\:").replacingOccurrences(of: "'", with: "\\'")
                filterGraph = "[0:v][1:v]scale2ref[dist][ref];[dist][ref]libvmaf=log_fmt=json:log_path=\(escaped):n_threads=0"
            } else {
                filterGraph = "[0:v][1:v]scale2ref[dist][ref];[dist][ref]libvmaf=n_threads=0"
            }
        }
        return [
            "-hide_banner",
            "-i", distortedURL.path,
            "-i", referenceURL.path,
            "-filter_complex", filterGraph,
            "-an", "-sn", "-dn",
            "-f", "null", "-"
        ]
    }
    
    public static func evaluate(
        distortedURL: URL,
        referenceURL: URL,
        metric: PerceptualQCMetric,
        ffmpegPath: String
    ) async -> PerceptualQCResult? {
        guard metric != .none else { return nil }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("strata_qc_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let vmafJSON = (metric == .libvmaf) ? tempDir.appendingPathComponent("vmaf.json") : nil
        guard let args = buildArguments(
            distortedURL: distortedURL,
            referenceURL: referenceURL,
            metric: metric,
            vmafJSONLogURL: vmafJSON
        ) else { return nil }
        
        let (status, stderr) = await runFFmpegCapture(ffmpegPath: ffmpegPath, arguments: args)
        guard status == 0 else { return nil }
        
        switch metric {
        case .none:
            return nil
        case .xpsnr:
            return parseXPSNR(stderr: stderr)
        case .libvmaf:
            if let vmafJSON,
               let data = try? Data(contentsOf: vmafJSON),
               let parsed = parseVMAFJSON(data: data) {
                return parsed
            }
            return parseVMAFFromStderr(stderr: stderr)
        }
    }
    
    /// Parses FFmpeg `xpsnr` summary line (e.g. `XPSNR y: 42.18 u: 45.10 v: 46.22 (min: 39.40)`).
    public static func parseXPSNR(stderr: String) -> PerceptualQCResult? {
        let pattern = #"XPSNR\s+(?:y|Y)\s*:\s*(-?[0-9]+(?:\.[0-9]+)?|inf)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stderr, range: NSRange(stderr.startIndex..., in: stderr)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: stderr) else {
            return nil
        }
        let raw = String(stderr[range])
        if raw.lowercased() == "inf" {
            return PerceptualQCResult(metric: .xpsnr, primaryScore: 99.9, summary: "XPSNR Y: ∞ dB (Lossless)")
        }
        guard let score = Double(raw) else { return nil }
        let summary = String(format: "XPSNR Y: %.2f dB", score)
        return PerceptualQCResult(metric: .xpsnr, primaryScore: score, summary: summary)
    }
    
    /// Parses `libvmaf` JSON report `pooled_metrics.vmaf.mean` (and optional harmonic_mean / min).
    public static func parseVMAFJSON(data: Data) -> PerceptualQCResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pooled = json["pooled_metrics"] as? [String: Any],
              let vmaf = pooled["vmaf"] as? [String: Any],
              let mean = vmaf["mean"] as? Double else {
            return nil
        }
        let minVal = vmaf["min"] as? Double
        let summary: String
        if let minVal {
            summary = String(format: "VMAF: %.2f (min %.1f)", mean, minVal)
        } else {
            summary = String(format: "VMAF: %.2f", mean)
        }
        return PerceptualQCResult(metric: .libvmaf, primaryScore: mean, summary: summary)
    }
    
    public static func parseVMAFFromStderr(stderr: String) -> PerceptualQCResult? {
        let pattern = #"VMAF score:\s*([0-9]+(?:\.[0-9]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stderr, range: NSRange(stderr.startIndex..., in: stderr)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: stderr),
              let score = Double(stderr[range]) else {
            return nil
        }
        return PerceptualQCResult(
            metric: .libvmaf,
            primaryScore: score,
            summary: String(format: "VMAF: %.2f", score)
        )
    }
    
    private static func runFFmpegCapture(ffmpegPath: String, arguments: [String]) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: ffmpegPath)
                proc.arguments = arguments
                let errPipe = Pipe()
                proc.standardInput = FileHandle.nullDevice
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = errPipe
                
                do {
                    try proc.run()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    continuation.resume(returning: (proc.terminationStatus, String(data: errData, encoding: .utf8) ?? ""))
                } catch {
                    continuation.resume(returning: (-1, ""))
                }
            }
        }
    }
}
