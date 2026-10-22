import Foundation

public struct RemuxProgress: Equatable {
    public let progress: Double // 0.0 to 1.0
    public let currentTime: Double // seconds
    public let totalTime: Double // seconds
    public let fps: Double
    public let speed: String
    public let bitrate: String
    public let frame: Int64
    public let remainingSeconds: Double?
    
    public init(
        progress: Double,
        currentTime: Double,
        totalTime: Double,
        fps: Double = 0,
        speed: String = "1.0x",
        bitrate: String = "",
        frame: Int64 = 0,
        remainingSeconds: Double? = nil
    ) {
        self.progress = max(0.0, min(1.0, progress))
        self.currentTime = currentTime
        self.totalTime = totalTime
        self.fps = fps
        self.speed = speed
        self.bitrate = bitrate
        self.frame = frame
        self.remainingSeconds = remainingSeconds
    }
}

public enum MediaFormatters {
    public static func formatDuration(_ seconds: Double) -> String {
        guard !seconds.isNaN && seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 {
            return String(format: "%02d:%02d:%02d", hrs, mins, secs)
        } else {
            return String(format: "%02d:%02d", mins, secs)
        }
    }
    
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useAll]
        return formatter
    }()
    
    public static func formatByteCount(_ bytes: Int64) -> String {
        byteCountFormatter.string(fromByteCount: bytes)
    }
    
    public static func formatBitrate(_ bps: Int64) -> String {
        if bps <= 0 { return "0 kbps" }
        let mbps = Double(bps) / 1_000_000.0
        if mbps >= 1.0 {
            return String(format: "%.1f Mbps", mbps)
        } else {
            return String(format: "%.0f kbps", Double(bps) / 1000.0)
        }
    }
    
    /// Parses "00:01:23.45" or "123.45" into seconds
    public static func parseTimeString(_ timeStr: String) -> Double? {
        let trimmed = timeStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Double(trimmed) {
            return direct
        }
        
        let components = trimmed.components(separatedBy: ":")
        if components.count == 3 {
            guard let h = Double(components[0]),
                  let m = Double(components[1]),
                  let s = Double(components[2]) else { return nil }
            return h * 3600 + m * 60 + s
        } else if components.count == 2 {
            guard let m = Double(components[0]),
                  let s = Double(components[1]) else { return nil }
            return m * 60 + s
        }
        return nil
    }
    
    /// Parses FFmpeg progress stderr line:
    /// "frame= 1234 fps= 60 q=-1.0 size= 1234kB time=00:00:20.50 bitrate= 492.3kbits/s speed=4.12x"
    public static func parseFFmpegProgress(line: String, totalDuration: Double) -> RemuxProgress? {
        // Must contain time=
        guard let timeRange = line.range(of: "time=") else { return nil }
        let afterTime = line[timeRange.upperBound...]
        let timeToken = afterTime.prefix { $0 != " " }
        guard let currentSeconds = parseTimeString(String(timeToken)) else { return nil }
        
        var fps: Double = 0.0
        if let fpsRange = line.range(of: "fps=") {
            let afterFps = line[fpsRange.upperBound...].trimmingCharacters(in: .whitespaces)
            let fpsToken = afterFps.prefix { $0 != " " }
            fps = Double(fpsToken) ?? 0.0
        }
        
        var speedStr = "1.0x"
        var speedMultiplier: Double = 1.0
        if let speedRange = line.range(of: "speed=") {
            let afterSpeed = line[speedRange.upperBound...].trimmingCharacters(in: .whitespaces)
            let spdToken = afterSpeed.prefix { $0 != " " && $0 != "\r" && $0 != "\n" }
            speedStr = String(spdToken)
            let cleanSpeed = speedStr.replacingOccurrences(of: "x", with: "")
            speedMultiplier = Double(cleanSpeed) ?? 1.0
        }
        
        var bitrateStr = ""
        if let brRange = line.range(of: "bitrate=") {
            let afterBr = line[brRange.upperBound...].trimmingCharacters(in: .whitespaces)
            let brToken = afterBr.prefix { $0 != " " }
            bitrateStr = String(brToken)
        }
        
        var frameNum: Int64 = 0
        if let frameRange = line.range(of: "frame=") {
            let afterFrame = line[frameRange.upperBound...].trimmingCharacters(in: .whitespaces)
            let frameToken = afterFrame.prefix { $0 != " " }
            frameNum = Int64(frameToken) ?? 0
        }
        
        let progress = totalDuration > 0 ? (currentSeconds / totalDuration) : 0.0
        
        var remainingSeconds: Double? = nil
        if totalDuration > 0 && speedMultiplier > 0.01 && currentSeconds < totalDuration {
            let remainingMedia = totalDuration - currentSeconds
            remainingSeconds = remainingMedia / speedMultiplier
        }
        
        return RemuxProgress(
            progress: progress,
            currentTime: currentSeconds,
            totalTime: totalDuration,
            fps: fps,
            speed: speedStr,
            bitrate: bitrateStr,
            frame: frameNum,
            remainingSeconds: remainingSeconds
        )
    }
}
