import Foundation

public struct MediaFile: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var url: URL
    public var filename: String
    public var fileSize: Int64
    public var containerFormat: String
    public var containerLongName: String
    public var duration: Double // in seconds
    public var startTime: Double
    public var overallBitRate: Int64
    public var tags: [String: String]
    public var tracks: [MediaTrack]
    public var chapters: [MediaChapter]
    
    public init(
        id: UUID = UUID(),
        url: URL,
        filename: String,
        fileSize: Int64,
        containerFormat: String,
        containerLongName: String = "",
        duration: Double = 0.0,
        startTime: Double = 0.0,
        overallBitRate: Int64 = 0,
        tags: [String: String] = [:],
        tracks: [MediaTrack] = [],
        chapters: [MediaChapter] = []
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.fileSize = fileSize
        self.containerFormat = containerFormat
        self.containerLongName = containerLongName
        self.duration = duration
        self.startTime = startTime
        self.overallBitRate = overallBitRate
        self.tags = tags
        self.tracks = tracks
        self.chapters = chapters
    }
    
    // Track filters
    public var videoTracks: [MediaTrack] {
        tracks.filter { $0.mediaType == .video }
    }
    
    public var audioTracks: [MediaTrack] {
        tracks.filter { $0.mediaType == .audio }
    }
    
    public var subtitleTracks: [MediaTrack] {
        tracks.filter { $0.mediaType == .subtitle }
    }
    
    public var selectedTracks: [MediaTrack] {
        tracks.filter { $0.isSelected }
    }
    
    // Quick summary
    public var summaryDescription: String {
        let vCount = videoTracks.count
        let aCount = audioTracks.count
        let sCount = subtitleTracks.count
        var parts: [String] = []
        if vCount > 0 { parts.append("\(vCount) Video") }
        if aCount > 0 { parts.append("\(aCount) Audio") }
        if sCount > 0 { parts.append("\(sCount) Subtitle\(sCount > 1 ? "s" : "")") }
        return parts.joined(separator: " • ")
    }
    
    // Formatted duration: HH:MM:SS or MM:SS
    public var formattedDuration: String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
    
    // Formatted file size
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
    // Formatted bit rate
    public var formattedBitRate: String {
        if overallBitRate <= 0 { return "Unknown" }
        let mbps = Double(overallBitRate) / 1_000_000.0
        if mbps >= 1.0 {
            return String(format: "%.1f Mbps", mbps)
        } else {
            let kbps = Double(overallBitRate) / 1000.0
            return String(format: "%.0f kbps", kbps)
        }
    }
    
    // Suggested output container based on extension
    public var suggestedContainer: ContainerFormat {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mkv": return .mkv
        case "m4v": return .m4v
        case "mov": return .mov
        case "webm": return .webm
        default: return .mp4
        }
    }
    
    // Clean, short format name for badges (e.g. "MP4", "MKV", "MOV")
    public var cleanFormatName: String {
        let ext = url.pathExtension.uppercased()
        if !ext.isEmpty && ext.count <= 5 { return ext }
        let lower = containerFormat.lowercased()
        if lower.contains("matroska") { return "MKV" }
        if lower.contains("mp4") { return "MP4" }
        if lower.contains("mov") { return "MOV" }
        if lower.contains("webm") { return "WEBM" }
        let first = containerFormat.split(separator: ",").first.map(String.init)?.uppercased() ?? "MEDIA"
        return first.count <= 5 ? first : suggestedContainer.shortName
    }
    
    // Exact duration including milliseconds (e.g. "00:17:05.320")
    public var preciseDuration: String {
        guard !duration.isNaN && duration >= 0 else { return "00:00:00.000" }
        let totalMs = Int((duration * 1000.0).rounded())
        let hrs = totalMs / 3_600_000
        let mins = (totalMs % 3_600_000) / 60_000
        let secs = (totalMs % 60_000) / 1000
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d.%03d", hrs, mins, secs, ms)
    }
    
    // Exact byte count formatted with grouping separators
    public var exactByteSizeFormatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let countStr = formatter.string(from: NSNumber(value: fileSize)) ?? "\(fileSize)"
        return "\(formattedSize) (\(countStr) bytes)"
    }
    
    public var dynamicRangeLabel: String? {
        videoTracks.first?.dynamicRangeBadge
    }
    
    public var writingApplication: String? {
        for key in ["writing_application", "encoder", "ENCODER"] {
            if let val = tags.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value {
                let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
    
    public var creationDateDisplay: String? {
        guard let raw = tags.first(where: { $0.key.caseInsensitiveCompare("creation_time") == .orderedSame })?.value else {
            return nil
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        if let parsed = date {
            let out = DateFormatter()
            out.dateStyle = .medium
            out.timeStyle = .short
            return out.string(from: parsed)
        }
        return raw
    }
    
    public var sortedTags: [(key: String, value: String)] {
        tags.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }
    
    public var technicalSummaryText: String {
        var lines: [String] = []
        lines.append("File: \(filename)")
        lines.append("Path: \(url.path)")
        let containerDesc = containerLongName.isEmpty ? cleanFormatName : "\(containerLongName) (\(cleanFormatName))"
        lines.append("Container: \(containerDesc)")
        lines.append("Size: \(exactByteSizeFormatted)")
        lines.append("Duration: \(preciseDuration)")
        if overallBitRate > 0 {
            lines.append("Overall Bit Rate: \(formattedBitRate)")
        }
        if let dr = dynamicRangeLabel {
            lines.append("Dynamic Range: \(dr)")
        }
        if let app = writingApplication {
            lines.append("Writing App: \(app)")
        }
        if let created = creationDateDisplay {
            lines.append("Created: \(created)")
        }
        
        for tr in tracks {
            lines.append("")
            lines.append("Stream #0:\(tr.streamIndex) (\(tr.mediaType.displayName)):")
            var codecParts = [tr.codecName.uppercased()]
            if let prof = tr.profile, !prof.isEmpty { codecParts.append(prof) }
            if let lvl = tr.codecLevelDisplay { codecParts.append("L\(lvl)") }
            if let tag = tr.codecTag { codecParts.append("[\(tag)]") }
            lines.append("  Codec: \(codecParts.joined(separator: " • "))")
            if let w = tr.width, let h = tr.height {
                var dim = "\(w)x\(h)"
                if let dar = tr.displayAspectRatio { dim += " (\(dar))" }
                lines.append("  Dimensions: \(dim)")
            }
            if let fps = tr.frameRate {
                lines.append("  Frame Rate: \(fps)")
            }
            if let fo = tr.formattedFieldOrder {
                lines.append("  Field Order: \(fo)")
            }
            if let cs = tr.formattedColorSpec {
                lines.append("  Color Space: \(cs)")
            }
            if let chroma = tr.chromaSubsamplingDisplay {
                let depthStr = tr.bitDepth.map { "\($0)-bit " } ?? ""
                lines.append("  Pixel Format: \(depthStr)\(chroma)")
            }
            if let ch = tr.channelDisplay {
                lines.append("  Channels: \(ch)")
            }
            if let sr = tr.formattedSampleRateDisplay {
                lines.append("  Sample Rate: \(sr)")
            }
            if let br = tr.formattedBitRate {
                lines.append("  Bit Rate: \(br)")
            }
            if let enc = tr.encoderName {
                lines.append("  Encoder: \(enc)")
            }
        }
        
        if !chapters.isEmpty {
            lines.append("")
            lines.append("Chapters (\(chapters.count)):")
            for ch in chapters {
                lines.append("  [\(ch.formattedStartTime)] \(ch.title)")
            }
        }
        
        return lines.joined(separator: "\n")
    }
}
