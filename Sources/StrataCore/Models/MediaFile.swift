import Foundation

public struct MediaFile: Identifiable, Hashable, Codable {
    public let id: UUID
    public var url: URL
    public var filename: String
    public var fileSize: Int64
    public var containerFormat: String
    public var containerLongName: String
    public var duration: Double // in seconds
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
}
