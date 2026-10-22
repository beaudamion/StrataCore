import Foundation

public enum ContainerFormat: String, CaseIterable, Identifiable, Codable {
    case mp4 = "mp4"
    case mkv = "mkv"
    case m4v = "m4v"
    case mov = "mov"
    case webm = "webm"
    
    public var id: String { rawValue }
    
    public var fileExtension: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .mp4: return "MP4 (MPEG-4)"
        case .mkv: return "MKV (Matroska)"
        case .m4v: return "M4V (Apple Video)"
        case .mov: return "MOV (QuickTime)"
        case .webm: return "WebM (HTML5)"
        }
    }
    
    public var shortName: String {
        rawValue.uppercased()
    }
    
    public var supportsFastStart: Bool {
        switch self {
        case .mp4, .m4v, .mov:
            return true
        default:
            return false
        }
    }
    
    public var recommendedAudioCodec: String {
        switch self {
        case .mp4, .m4v:
            return "aac"
        case .mov:
            return "aac"
        case .mkv:
            return "copy"
        case .webm:
            return "libopus"
        }
    }
    
    public var recommendedSubtitleCodec: String {
        switch self {
        case .mp4, .m4v, .mov:
            return "mov_text"
        case .mkv:
            return "copy"
        case .webm:
            return "webvtt"
        }
    }
}
