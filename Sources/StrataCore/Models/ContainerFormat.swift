import Foundation

public enum ContainerFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    // Video Containers
    case mp4 = "mp4"
    case mkv = "mkv"
    case m4v = "m4v"
    case mov = "mov"
    case webm = "webm"
    
    // Audio Containers
    case m4a = "m4a"
    case wav = "wav"
    case aiff = "aiff"
    case flac = "flac"
    case mp3 = "mp3"
    case opus = "opus"
    case ogg = "ogg"
    case caf = "caf"
    
    public var id: String { rawValue }
    
    public var fileExtension: String { rawValue }
    
    public var isVideoContainer: Bool {
        switch self {
        case .mp4, .mkv, .m4v, .mov, .webm:
            return true
        default:
            return false
        }
    }
    
    public var isAudioContainer: Bool {
        switch self {
        case .m4a, .wav, .aiff, .flac, .mp3, .opus, .ogg, .caf, .mkv:
            return true
        default:
            return false
        }
    }
    
    public static let videoContainers: [ContainerFormat] = [
        .mp4, .mkv, .mov, .m4v, .webm
    ]
    
    public static let audioContainers: [ContainerFormat] = [
        .m4a, .flac, .wav, .aiff, .mp3, .opus, .ogg, .caf, .mkv
    ]
    
    public var supportsMultiTrackAudio: Bool {
        switch self {
        case .mp4, .mkv, .mov, .m4a, .caf:
            return true
        default:
            return false
        }
    }
    
    public var displayName: String {
        switch self {
        // Video Containers
        case .mp4: return "MP4 (MPEG-4)"
        case .mkv: return "MKV (Matroska)"
        case .m4v: return "M4V (Apple Video)"
        case .mov: return "MOV (QuickTime)"
        case .webm: return "WebM (HTML5)"
            
        // Audio Containers
        case .m4a: return "M4A (Apple Audio)"
        case .flac: return "FLAC (Lossless)"
        case .wav: return "WAV (Uncompressed PCM)"
        case .aiff: return "AIFF (Apple Uncompressed)"
        case .mp3: return "MP3 (MPEG Layer 3)"
        case .opus: return "Opus (High Efficiency)"
        case .ogg: return "OGG (Ogg Vorbis)"
        case .caf: return "CAF (Apple Core Audio)"
        }
    }
    
    public var shortName: String {
        rawValue.uppercased()
    }
    
    public var supportsFastStart: Bool {
        switch self {
        case .mp4, .m4v, .mov, .m4a:
            return true
        default:
            return false
        }
    }
    
    public var defaultAudioAction: TrackAction {
        switch self {
        case .m4a: return .transcodeALAC
        case .flac: return .transcodeFLAC
        case .wav: return .transcodeWAV
        case .aiff: return .transcodeAIFF
        case .mp3: return .transcodeMP3
        case .opus: return .transcodeOpus
        case .ogg: return .transcodeVorbis
        case .caf: return .transcodeALAC
        case .webm: return .transcodeOpus
        case .mp4, .m4v, .mov: return .transcodeAAC
        case .mkv: return .copy
        }
    }
    
    public var recommendedAudioCodec: String {
        switch self {
        case .mp4, .m4v, .mov:
            return "aac"
        case .mkv:
            return "copy"
        case .webm, .opus:
            return "libopus"
        case .m4a:
            return "alac"
        case .flac:
            return "flac"
        case .wav:
            return "pcm_s16le"
        case .aiff:
            return "aiff"
        case .mp3:
            return "libmp3lame"
        case .ogg:
            return "libvorbis"
        case .caf:
            return "alac"
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
        default:
            return "none"
        }
    }
    
    public func supportsVideoAction(_ action: TrackAction) -> Bool {
        guard isVideoContainer else { return false }
        guard action != .copy else { return true }
        switch self {
        case .mov:
            return action != .transcodeAV1
        case .mp4, .m4v:
            return action == .transcodeH264_VT || action == .transcodeHEVC_VT || action == .transcodeAV1
        case .mkv:
            return true
        case .webm:
            return action == .transcodeAV1
        default:
            return false
        }
    }
    
    public func supportsAudioAction(_ action: TrackAction) -> Bool {
        guard action != .copy else { return true }
        switch self {
        case .m4a:
            return action == .transcodeALAC || action == .transcodeAAC
        case .wav:
            return action == .transcodeWAV
        case .aiff:
            return action == .transcodeAIFF
        case .flac:
            return action == .transcodeFLAC
        case .mp3:
            return action == .transcodeMP3
        case .opus:
            return action == .transcodeOpus
        case .ogg:
            return action == .transcodeVorbis
        case .caf:
            return action == .transcodeALAC || action == .transcodeAIFF || action == .transcodeWAV || action == .transcodeAAC
        case .webm:
            return action == .transcodeOpus
        case .mp4, .m4v:
            return action == .transcodeAAC || action == .transcodeALAC || action == .transcodeAC3_51 || action == .transcodeEAC3_51 || action == .transcodeMP3
        case .mov:
            return action == .transcodeAAC || action == .transcodeALAC || action == .transcodeAIFF || action == .transcodeWAV || action == .transcodeAC3_51 || action == .transcodeEAC3_51
        case .mkv:
            return true
        }
    }
    
    public func recommendedContainersDescription(forVideoAction action: TrackAction) -> String {
        switch action {
        case .transcodeAV1:
            return "MP4, M4V, MKV, or WebM"
        case .transcodeProRes, .transcodeUncompressed:
            return "MOV (QuickTime) or MKV"
        case .transcodeH264_VT, .transcodeHEVC_VT:
            return "MP4, M4V, MOV, or MKV"
        default:
            return "MP4, MKV, or MOV"
        }
    }
}
