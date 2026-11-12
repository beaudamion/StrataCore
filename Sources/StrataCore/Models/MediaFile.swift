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
        let fmtDisplay = containerLongName.isEmpty ? cleanFormatName : containerLongName
        lines.append("Container & File:")
        lines.append("  File: \(filename)")
        lines.append("  Path: \(url.path)")
        lines.append("  Folder: \(url.deletingLastPathComponent().path)")
        lines.append("  Format: \(fmtDisplay)")
        lines.append("  Exact Duration: \(preciseDuration)")
        lines.append("  File Size: \(exactByteSizeFormatted)")
        if overallBitRate > 0 {
            lines.append("  Overall Bit Rate: \(formattedBitRate)")
        }
        lines.append("  Total Streams: \(tracks.count)")
        if abs(startTime) > 0.001 {
            lines.append("  Start Offset: \(String(format: "%.3f s", startTime))")
        }
        if let dr = dynamicRangeLabel {
            lines.append("  Dynamic Range: \(dr)")
        }
        if let app = writingApplication {
            lines.append("  Writing App: \(app)")
        }
        if let created = creationDateDisplay {
            lines.append("  Created: \(created)")
        }

        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal

        for tr in tracks {
            lines.append("")
            lines.append("Stream #0:\(tr.streamIndex) (\(tr.mediaType.displayName)):")
            if tr.mediaType == .audio || tr.mediaType == .subtitle ||
                tr.mediaType == .attachment || tr.mediaType == .data || tr.mediaType == .other ||
                (!tr.language.isEmpty && tr.language.lowercased() != "und") {
                lines.append("  Language: \(LanguageDirectory.displayName(for: tr.language))")
            }
            if !tr.title.isEmpty {
                lines.append("  Title: \(tr.title)")
            }

            var codecParts = [tr.codecName.uppercased()]
            if let prof = tr.profile, !prof.isEmpty { codecParts.append(prof) }
            if let lvl = tr.codecLevelDisplay { codecParts.append("L\(lvl)") }
            if let tag = tr.codecTag { codecParts.append("[\(tag)]") }
            lines.append("  Codec: \(codecParts.joined(separator: " • "))")

            if let long = tr.codecLongName, !long.isEmpty {
                lines.append("  Standard: \(long)")
            }
            if let w = tr.width, let h = tr.height {
                lines.append("  Dimensions: \(w) × \(h)")
            }
            if tr.displayAspectRatio != nil || tr.sampleAspectRatio != nil {
                var arParts: [String] = []
                if let dar = tr.displayAspectRatio { arParts.append("\(dar) (Display)") }
                if let sar = tr.sampleAspectRatio {
                    arParts.append(sar == "1:1" ? "1:1 Square" : "\(sar) PAR")
                }
                lines.append("  Aspect Ratio: \(arParts.joined(separator: " • "))")
            }
            if let fps = tr.frameRate {
                let vfrTag = (tr.isVariableFrameRate == true) ? " (VFR)" : (tr.isVariableFrameRate == false ? " (CFR)" : "")
                lines.append("  Frame Rate: \(fps)\(vfrTag)")
            }
            if let fo = tr.formattedFieldOrder {
                lines.append("  Field Order: \(fo)")
            }
            if let cs = tr.formattedColorSpec {
                lines.append("  Color Space: \(cs)")
            }
            if let cr = tr.formattedColorRange {
                lines.append("  Color Range: \(cr)")
            }
            if tr.chromaSubsamplingDisplay != nil || tr.bitDepth != nil || tr.pixelFormat != nil {
                var pxParts: [String] = []
                if let bd = tr.bitDepth { pxParts.append("\(bd)-bit") }
                if let chroma = tr.chromaSubsamplingDisplay { pxParts.append(chroma) }
                if let pf = tr.pixelFormat { pxParts.append(pf) }
                lines.append("  Pixel Format: \(pxParts.joined(separator: " • "))")
            }
            if let cl = tr.chromaLocation, !cl.isEmpty {
                lines.append("  Chroma Loc.: \(cl.capitalized)")
            }
            if let bf = tr.hasBFrames {
                lines.append("  B-Frames: \(bf > 0 ? "\(bf) reorder" : "None (0)")")
            }
            if let tb = tr.timeBase, !tb.isEmpty {
                lines.append("  Timebase: \(tb)")
            }
            if let md = tr.formattedMasteringDisplay {
                lines.append("  HDR10 Mastering: \(md)")
            }
            if let cll = tr.formattedContentLightLevel {
                lines.append("  MaxCLL / MaxFALL: \(cll)")
            }
            if let dv = tr.formattedDolbyVision {
                lines.append("  Dolby Vision: \(dv)")
            }
            if let fc = tr.frameCount, fc > 0 {
                let grouped = numberFormatter.string(from: NSNumber(value: fc)) ?? "\(fc)"
                lines.append("  Frame Count: \(grouped)")
            }
            if let ch = tr.channelDisplay {
                lines.append("  Channels: \(ch)")
            }
            if let sr = tr.formattedSampleRateDisplay {
                lines.append("  Sample Rate: \(sr)")
            }
            if let sf = tr.formattedSampleFormat {
                lines.append("  Sample Format: \(sf)")
            }
            if let br = tr.formattedBitRate {
                let label = tr.mediaType == .video ? "Stream Bit Rate" : "Bit Rate"
                lines.append("  \(label): \(br)")
            }
            if let tc = tr.startTimecode {
                lines.append("  Timecode: \(tc)")
            }
            if let enc = tr.encoderName {
                lines.append("  Encoder: \(enc)")
            }
            if !tr.dispositionFlags.isEmpty {
                lines.append("  Flags: \(tr.dispositionFlags.joined(separator: ", "))")
            }
            if tr.isExternal, let extURL = tr.externalURL {
                lines.append("  External Source: \(extURL.path)")
            }
        }

        let tagsList = sortedTags
        if !tagsList.isEmpty {
            lines.append("")
            lines.append("Metadata Tags (\(tagsList.count)):")
            for item in tagsList {
                lines.append("  \(item.key): \(item.value)")
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
