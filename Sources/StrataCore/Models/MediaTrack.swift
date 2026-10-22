import Foundation
import SwiftUI

public enum MediaType: String, Codable, CaseIterable {
    case video = "video"
    case audio = "audio"
    case subtitle = "subtitle"
    case attachment = "attachment"
    case data = "data"
    case other = "other"
    
    public var displayName: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .subtitle: return "Subtitle"
        case .attachment: return "Attachment"
        case .data: return "Data"
        case .other: return "Other"
        }
    }
    
    public var systemImage: String {
        switch self {
        case .video: return "film.fill"
        case .audio: return "waveform"
        case .subtitle: return "captions.bubble.fill"
        case .attachment: return "paperclip"
        case .data: return "doc.text.fill"
        case .other: return "questionmark.square.dashed"
        }
    }
    
    public var tintColor: Color {
        switch self {
        case .video: return Color(red: 0.78, green: 0.38, blue: 1.00)
        case .audio: return Color(red: 1.00, green: 0.58, blue: 0.16)
        case .subtitle: return Color(red: 0.18, green: 0.85, blue: 0.55)
        case .attachment: return Color(red: 0.48, green: 0.55, blue: 0.95)
        case .data: return .gray
        case .other: return .secondary
        }
    }
}

public enum TrackAction: String, Codable, CaseIterable, Identifiable {
    // Universal
    case copy = "copy"
    
    // Video Transcoding (Hardware accelerated on Apple Silicon)
    case transcodeH264_VT = "transcode_h264_vt"
    case transcodeHEVC_VT = "transcode_hevc_vt"
    case transcodeProRes = "transcode_prores"
    
    // Audio Transcoding
    case transcodeAAC_Stereo = "transcode_aac_stereo"
    case transcodeAAC_51 = "transcode_aac_51"
    case transcodeMP3 = "transcode_mp3"
    case transcodeALAC = "transcode_alac"
    case transcodeAC3_51 = "transcode_ac3_51"
    case transcodeEAC3_51 = "transcode_eac3_51"
    case transcodeOpus = "transcode_opus"
    case transcodeFLAC = "transcode_flac"
    case transcodeWAV = "transcode_wav"
    case transcodeAIFF = "transcode_aiff"
    
    // Subtitle Conversion
    case transcodeSRT = "transcode_srt"
    case transcodeMovText = "transcode_mov_text"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .copy:
            return "Passthrough (Copy)"
        case .transcodeH264_VT:
            return "H.264 (VideoToolbox)"
        case .transcodeHEVC_VT:
            return "HEVC / H.265 (VideoToolbox)"
        case .transcodeProRes:
            return "Apple ProRes 422"
        case .transcodeAAC_Stereo:
            return "AAC Stereo"
        case .transcodeAAC_51:
            return "AAC 5.1 Surround"
        case .transcodeMP3:
            return "MP3 (LAME)"
        case .transcodeALAC:
            return "Apple Lossless (ALAC)"
        case .transcodeAC3_51:
            return "AC3 5.1 Surround"
        case .transcodeEAC3_51:
            return "E-AC3 5.1 (Dolby Digital+)"
        case .transcodeOpus:
            return "Opus"
        case .transcodeFLAC:
            return "FLAC (Lossless)"
        case .transcodeWAV:
            return "WAV (Uncompressed PCM)"
        case .transcodeAIFF:
            return "AIFF (Apple Uncompressed)"
        case .transcodeSRT:
            return "SubRip (.srt)"
        case .transcodeMovText:
            return "MP4 Timed Text (mov_text)"
        }
    }
    
    public static let videoActions: [TrackAction] = [
        .copy,
        .transcodeProRes,
        .transcodeH264_VT,
        .transcodeHEVC_VT
    ]
    
    public static let audioActions: [TrackAction] = [
        .copy,
        .transcodeAAC_51,
        .transcodeAAC_Stereo,
        .transcodeAC3_51,
        .transcodeAIFF,
        .transcodeALAC,
        .transcodeEAC3_51,
        .transcodeFLAC,
        .transcodeMP3,
        .transcodeOpus,
        .transcodeWAV
    ]
    
    public static let subtitleActions: [TrackAction] = [
        .copy,
        .transcodeMovText,
        .transcodeSRT
    ]
    
    public static let defaultActions: [TrackAction] = [.copy]
    
    public static func availableActions(for mediaType: MediaType) -> [TrackAction] {
        switch mediaType {
        case .video: return videoActions
        case .audio: return audioActions
        case .subtitle: return subtitleActions
        default: return defaultActions
        }
    }
    
    public var isTranscode: Bool {
        self != .copy
    }
    
    public var supportsAudioConfig: Bool {
        switch self {
        case .transcodeAAC_Stereo, .transcodeAAC_51, .transcodeMP3, .transcodeALAC,
             .transcodeAC3_51, .transcodeEAC3_51, .transcodeOpus, .transcodeFLAC,
             .transcodeWAV, .transcodeAIFF:
            return true
        default:
            return false
        }
    }
}

public struct AudioEncodingConfig: Hashable, Codable {
    public var bitrate: String // "128k", "192k", "256k", "320k", "V0", "V2"
    public var sampleRate: String? // "44100", "48000", "96000", or nil for Auto
    public var channels: Int? // 1, 2, 6, or nil for Auto
    public var bitDepth: String? // "16", "24" for ALAC/FLAC
    public var isVBR: Bool
    
    public init(
        bitrate: String = "192k",
        sampleRate: String? = nil,
        channels: Int? = nil,
        bitDepth: String? = nil,
        isVBR: Bool = false
    ) {
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.isVBR = isVBR
    }
    
    public static func `default`(for action: TrackAction) -> AudioEncodingConfig {
        switch action {
        case .transcodeMP3:
            return AudioEncodingConfig(bitrate: "320k", isVBR: false)
        case .transcodeALAC:
            return AudioEncodingConfig(bitrate: "Lossless", bitDepth: nil)
        case .transcodeAAC_Stereo:
            return AudioEncodingConfig(bitrate: "192k", channels: 2)
        case .transcodeAAC_51:
            return AudioEncodingConfig(bitrate: "384k", channels: 6)
        case .transcodeAC3_51:
            return AudioEncodingConfig(bitrate: "640k", channels: 6)
        case .transcodeEAC3_51:
            return AudioEncodingConfig(bitrate: "640k", channels: 6)
        case .transcodeOpus:
            return AudioEncodingConfig(bitrate: "510k", channels: 2)
        case .transcodeFLAC:
            return AudioEncodingConfig(bitrate: "Lossless", bitDepth: nil)
        case .transcodeWAV:
            return AudioEncodingConfig(bitrate: "Uncompressed", bitDepth: nil)
        case .transcodeAIFF:
            return AudioEncodingConfig(bitrate: "Uncompressed", bitDepth: nil)
        default:
            return AudioEncodingConfig()
        }
    }
}

public struct MediaTrack: Identifiable, Hashable, Codable {
    public let id: UUID
    public var streamIndex: Int
    public var mediaType: MediaType
    public var codecName: String
    public var codecLongName: String?
    public var profile: String?
    
    // Video specific
    public var width: Int?
    public var height: Int?
    public var frameRate: String?
    public var pixelFormat: String?
    public var colorSpace: String?
    
    // Audio specific
    public var channels: Int?
    public var channelLayout: String?
    public var sampleRate: String?
    
    // Common
    public var bitRate: Int64?
    public var language: String
    public var title: String
    public var isDefault: Bool
    public var isForced: Bool
    
    // User configuration
    public var isSelected: Bool
    public var action: TrackAction
    public var audioConfig: AudioEncodingConfig
    
    // External source (e.g. imported .srt, .ass)
    public var isExternal: Bool
    public var externalURL: URL?
    
    public init(
        id: UUID = UUID(),
        streamIndex: Int,
        mediaType: MediaType,
        codecName: String,
        codecLongName: String? = nil,
        profile: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        frameRate: String? = nil,
        pixelFormat: String? = nil,
        colorSpace: String? = nil,
        channels: Int? = nil,
        channelLayout: String? = nil,
        sampleRate: String? = nil,
        bitRate: Int64? = nil,
        language: String = "und",
        title: String = "",
        isDefault: Bool = false,
        isForced: Bool = false,
        isSelected: Bool = true,
        action: TrackAction = .copy,
        audioConfig: AudioEncodingConfig? = nil,
        isExternal: Bool = false,
        externalURL: URL? = nil
    ) {
        self.id = id
        self.streamIndex = streamIndex
        self.mediaType = mediaType
        self.codecName = codecName
        self.codecLongName = codecLongName
        self.profile = profile
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.pixelFormat = pixelFormat
        self.colorSpace = colorSpace
        self.channels = channels
        self.channelLayout = channelLayout
        self.sampleRate = sampleRate
        self.bitRate = bitRate
        self.language = language
        self.title = title
        self.isDefault = isDefault
        self.isForced = isForced
        self.isSelected = isSelected
        self.action = action
        self.audioConfig = audioConfig ?? AudioEncodingConfig.default(for: action)
        self.isExternal = isExternal
        self.externalURL = externalURL
    }
    
    public var resolutionDisplay: String? {
        guard let width = width, let height = height else { return nil }
        var str = "\(width)x\(height)"
        if let fps = frameRate, !fps.isEmpty, fps != "0/0" {
            str += " @ \(fps)"
        }
        return str
    }
    
    public var channelDisplay: String? {
        if let layout = channelLayout, !layout.isEmpty {
            return layout
        }
        if let channels = channels {
            switch channels {
            case 1: return "Mono (1.0)"
            case 2: return "Stereo (2.0)"
            case 6: return "5.1 Surround"
            case 8: return "7.1 Surround"
            default: return "\(channels) Channels"
            }
        }
        return nil
    }
    
    public var detailsDisplay: String {
        switch mediaType {
        case .video:
            return resolutionDisplay ?? "Video Stream"
        case .audio:
            var parts: [String] = []
            if let ch = channelDisplay { parts.append(ch) }
            if let sr = sampleRate, let srInt = Int(sr) {
                parts.append("\(srInt / 1000) kHz")
            }
            if let br = bitRate, br > 0 {
                parts.append("\(br / 1000) kbps")
            }
            return parts.isEmpty ? "Audio Stream" : parts.joined(separator: " • ")
        case .subtitle:
            return isExternal ? "External File" : "Embedded Subtitle"
        case .attachment:
            return "Attachment File"
        case .data:
            return "Data Stream"
        case .other:
            return "Stream"
        }
    }
    
    public var exportExtension: String {
        if action == .copy {
            switch codecName.lowercased() {
            // Audio formats
            case "aac", "alac": return "m4a"
            case "mp3": return "mp3"
            case "ac3": return "ac3"
            case "eac3": return "eac3"
            case "flac": return "flac"
            case "opus": return "opus"
            case "wav": return "wav"
            case "aiff": return "aiff"
            
            // Subtitle formats
            case "subrip", "srt": return "srt"
            case "ass", "ssa": return "ass"
            case "webvtt", "vtt": return "vtt"
            
            // Video formats
            case "prores", "apcn", "apch", "apco", "ap4h", "ap4x": return "mov"
            case "vp9", "vp8": return "webm"
            case "h264", "avc", "avc1", "hevc", "h265", "hev1", "hvc1", "av1", "mpeg4", "mp4v", "mpeg2video", "mjpeg": return "mp4"
            
            default:
                if mediaType == .video { return "mp4" }
                if mediaType == .audio { return "m4a" }
                if mediaType == .subtitle { return "srt" }
                return "dat"
            }
        } else {
            switch action {
            // Video Transcoding
            case .transcodeProRes: return "mov"
            case .transcodeH264_VT, .transcodeHEVC_VT: return "mp4"
            
            // Audio Transcoding
            case .transcodeALAC, .transcodeAAC_Stereo, .transcodeAAC_51: return "m4a"
            case .transcodeMP3: return "mp3"
            case .transcodeFLAC: return "flac"
            case .transcodeOpus: return "opus"
            case .transcodeAC3_51: return "ac3"
            case .transcodeEAC3_51: return "eac3"
            case .transcodeWAV: return "wav"
            case .transcodeAIFF: return "aiff"
            
            // Subtitle Conversion
            case .transcodeSRT: return "srt"
            case .transcodeMovText: return "m4a"
            
            default:
                if mediaType == .video { return "mp4" }
                if mediaType == .subtitle { return "srt" }
                return "m4a"
            }
        }
    }
}
