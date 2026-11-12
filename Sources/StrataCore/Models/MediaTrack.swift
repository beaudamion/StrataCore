import Foundation
import SwiftUI

public enum MediaType: String, Codable, CaseIterable, Sendable {
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

public enum TrackAction: String, Codable, CaseIterable, Identifiable, Sendable {
    // Universal
    case copy = "copy"
    
    // Video Transcoding (Hardware accelerated on Apple Silicon)
    case transcodeH264_VT = "transcode_h264_vt"
    case transcodeHEVC_VT = "transcode_hevc_vt"
    case transcodeProRes = "transcode_prores"
    
    // Video Transcoding (Software / Uncompressed)
    case transcodeAV1 = "transcode_av1"
    case transcodeUncompressed = "transcode_uncompressed"
    
    // Audio Transcoding
    case transcodeAAC = "transcode_aac"
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
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "transcode_uncompressed_8" || raw == "transcode_uncompressed_10" {
            self = .transcodeUncompressed
        } else if raw == "transcode_aac_stereo" || raw == "transcode_aac_51" {
            self = .transcodeAAC
        } else if let action = TrackAction(rawValue: raw) {
            self = action
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown TrackAction rawValue: \(raw)")
        }
    }
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .copy:
            return "Passthrough"
        case .transcodeH264_VT:
            return "H.264"
        case .transcodeHEVC_VT:
            return "HEVC / H.265"
        case .transcodeAV1:
            return "AV1"
        case .transcodeProRes:
            return "Apple ProRes"
        case .transcodeUncompressed:
            return "Uncompressed"
        case .transcodeAAC:
            return "AAC"
        case .transcodeMP3:
            return "MP3 (LAME)"
        case .transcodeALAC:
            return "Apple Lossless (ALAC)"
        case .transcodeAC3_51:
            return "AC3"
        case .transcodeEAC3_51:
            return "E-AC3 (Dolby Digital+)"
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
        .transcodeUncompressed,
        .transcodeH264_VT,
        .transcodeHEVC_VT,
        .transcodeAV1
    ]
    
    public static let audioActions: [TrackAction] = [
        .copy,
        .transcodeAAC,
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
        case .transcodeAAC, .transcodeMP3, .transcodeALAC,
             .transcodeAC3_51, .transcodeEAC3_51, .transcodeOpus, .transcodeFLAC,
             .transcodeWAV, .transcodeAIFF:
            return true
        default:
            return false
        }
    }
    
    public var supportsVideoConfig: Bool {
        switch self {
        case .transcodeH264_VT, .transcodeHEVC_VT, .transcodeAV1, .transcodeProRes, .transcodeUncompressed:
            return true
        default:
            return false
        }
    }
    
    public var supportsConfig: Bool {
        supportsAudioConfig || supportsVideoConfig
    }
}

public enum VideoColorSpace: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case rec709 = "rec709"
    case rec601NTSC = "rec601_ntsc"
    case rec601PAL = "rec601_pal"
    case rec2020 = "rec2020"
    case rec2020HLG = "rec2020_hlg"
    case rec2020PQ = "rec2020_pq"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .rec709: return "Rec. 709 (1-1-1)"
        case .rec601NTSC: return "Rec. 601 (NTSC)"
        case .rec601PAL: return "Rec. 601 (PAL)"
        case .rec2020: return "Rec. 2020 (SDR)"
        case .rec2020HLG: return "Rec. 2020 HLG (10-bit)"
        case .rec2020PQ: return "Rec. 2020 PQ (HDR10)"
        }
    }
    
    public var ffPrimaries: String? {
        switch self {
        case .auto: return nil
        case .rec709: return "bt709"
        case .rec601NTSC: return "smpte170m"
        case .rec601PAL: return "bt470bg"
        case .rec2020, .rec2020HLG, .rec2020PQ: return "bt2020"
        }
    }
    
    public var ffTransfer: String? {
        switch self {
        case .auto: return nil
        case .rec709: return "bt709"
        case .rec601NTSC: return "smpte170m"
        case .rec601PAL: return "bt470bg"
        case .rec2020: return "bt2020-10"
        case .rec2020HLG: return "arib-std-b67"
        case .rec2020PQ: return "smpte2084"
        }
    }
    
    public var ffMatrix: String? {
        switch self {
        case .auto: return nil
        case .rec709: return "bt709"
        case .rec601NTSC: return "smpte170m"
        case .rec601PAL: return "bt470bg"
        case .rec2020, .rec2020HLG, .rec2020PQ: return "bt2020nc"
        }
    }
}

public enum VideoEntropyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case cabac = "cabac"
    case cavlc = "cavlc"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .cabac: return "CABAC"
        case .cavlc: return "CAVLC"
        }
    }
}

public enum VideoFieldOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case progressive = "progressive"
    case topFirst = "tt"
    case bottomFirst = "bb"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .progressive: return "Progressive"
        case .topFirst: return "Top First"
        case .bottomFirst: return "Bottom First"
        }
    }
}

public enum VideoRateControlMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case constantQuality = "constant_quality"
    case averageBitrate = "average_bitrate"
    case twoPassVBR = "two_pass_vbr"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .constantQuality: return "Constant Quality"
        case .averageBitrate: return "Average Bitrate"
        case .twoPassVBR: return "2-Pass VBR"
        }
    }
}

public enum VideoQualityPreset: String, CaseIterable, Identifiable, Sendable {
    case compact = "compact"
    case balanced = "balanced"
    case high = "high"
    case master = "master"
    
    public var id: String { rawValue }
    
    public var qualityValue: Int {
        switch self {
        case .compact: return 55
        case .balanced: return 65
        case .high: return 72
        case .master: return 80
        }
    }
    
    public var displayName: String {
        switch self {
        case .compact: return "Compact (55)"
        case .balanced: return "Balanced (65)"
        case .high: return "High (72)"
        case .master: return "Master (80)"
        }
    }
    
    public static func matching(quality: Int) -> VideoQualityPreset? {
        allCases.first { $0.qualityValue == quality }
    }
}

public enum VideoDeinterlaceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case off = "off"
    case force = "force"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .off: return "Off"
        case .force: return "Force Deinterlace"
        }
    }
}

public enum VideoResizeOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case original = "original"
    case uhd4K = "3840"
    case qhd1440 = "2560"
    case fhd1080 = "1920"
    case hd720 = "1280"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .original: return "Original Size"
        case .uhd4K: return "4K UHD (3840w)"
        case .qhd1440: return "1440p QHD (2560w)"
        case .fhd1080: return "1080p HD (1920w)"
        case .hd720: return "720p HD (1280w)"
        }
    }
    
    public var targetWidth: Int? {
        switch self {
        case .original: return nil
        case .uhd4K: return 3840
        case .qhd1440: return 2560
        case .fhd1080: return 1920
        case .hd720: return 1280
        }
    }
}

public enum VideoRotation: String, Codable, CaseIterable, Identifiable, Sendable {
    case none = "none"
    case clockwise90 = "clock"
    case counterClockwise90 = "cclock"
    case rotate180 = "reversal"
    case flipHorizontal = "hflip"
    case flipVertical = "vflip"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .none: return "None"
        case .clockwise90: return "90° Clockwise"
        case .counterClockwise90: return "90° Counter-CW"
        case .rotate180: return "180° Rotate"
        case .flipHorizontal: return "Flip Horizontal"
        case .flipVertical: return "Flip Vertical"
        }
    }
    
    public var transposeVTDir: String? {
        self == .none ? nil : rawValue
    }
    
    public var cpuFilterExpression: String? {
        switch self {
        case .none: return nil
        case .clockwise90: return "transpose=1"
        case .counterClockwise90: return "transpose=2"
        case .rotate180: return "transpose=2,transpose=2"
        case .flipHorizontal: return "hflip"
        case .flipVertical: return "vflip"
        }
    }
}

public enum AudioAACEncodingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case vbrQuality = "vbr"
    case cbr = "cbr"
    case abr = "abr"
    case cvbr = "cvbr"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .vbrQuality: return "True VBR Quality"
        case .cbr: return "CBR (Constant)"
        case .abr: return "ABR (Average)"
        case .cvbr: return "CVBR (Constrained)"
        }
    }
}

public enum AudioLoudnessTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case off = "off"
    case streaming14 = "lufs_14"
    case podcast16 = "lufs_16"
    case broadcast23 = "lufs_23"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .streaming14: return "-14 LUFS (Streaming)"
        case .podcast16: return "-16 LUFS (Apple/Podcast)"
        case .broadcast23: return "-23 LUFS (EBU R128)"
        }
    }
    
    public var shortLabel: String {
        switch self {
        case .off: return "Off"
        case .streaming14: return "-14 LUFS"
        case .podcast16: return "-16 LUFS"
        case .broadcast23: return "-23 LUFS"
        }
    }
    
    public var integratedLUFS: Double? {
        switch self {
        case .off: return nil
        case .streaming14: return -14.0
        case .podcast16: return -16.0
        case .broadcast23: return -23.0
        }
    }
    
    public var truePeakDBTP: Double {
        switch self {
        case .off: return -1.5
        case .streaming14: return -1.0
        case .podcast16: return -1.5
        case .broadcast23: return -2.0
        }
    }
    
    public var lraTarget: Double {
        switch self {
        case .broadcast23: return 7.0
        default: return 11.0
        }
    }
}

public struct HDRMasteringDisplay: Hashable, Codable, Sendable {
    public var redX: Double?
    public var redY: Double?
    public var greenX: Double?
    public var greenY: Double?
    public var blueX: Double?
    public var blueY: Double?
    public var whitePointX: Double?
    public var whitePointY: Double?
    public var minLuminance: Double?
    public var maxLuminance: Double?
    
    public init(
        redX: Double? = nil,
        redY: Double? = nil,
        greenX: Double? = nil,
        greenY: Double? = nil,
        blueX: Double? = nil,
        blueY: Double? = nil,
        whitePointX: Double? = nil,
        whitePointY: Double? = nil,
        minLuminance: Double? = nil,
        maxLuminance: Double? = nil
    ) {
        self.redX = redX
        self.redY = redY
        self.greenX = greenX
        self.greenY = greenY
        self.blueX = blueX
        self.blueY = blueY
        self.whitePointX = whitePointX
        self.whitePointY = whitePointY
        self.minLuminance = minLuminance
        self.maxLuminance = maxLuminance
    }
    
    public var hasPrimaries: Bool {
        redX != nil && redY != nil && greenX != nil && greenY != nil && blueX != nil && blueY != nil && whitePointX != nil && whitePointY != nil
    }
    
    public var hasLuminance: Bool {
        maxLuminance != nil && minLuminance != nil
    }
    
    public var formattedSummary: String? {
        var parts: [String] = []
        if let rx = redX, let gx = greenX {
            if abs(rx - 0.680) < 0.02 && abs(gx - 0.265) < 0.02 {
                parts.append("Display P3")
            } else if abs(rx - 0.708) < 0.02 && abs(gx - 0.170) < 0.02 {
                parts.append("BT.2020")
            } else {
                parts.append(String(format: "RGB(%.3f,%.3f)", rx, redY ?? 0))
            }
        }
        if let maxL = maxLuminance {
            if let minL = minLuminance {
                parts.append(String(format: "%.4g–%.0f cd/m²", minL, maxL))
            } else {
                parts.append(String(format: "%.0f cd/m²", maxL))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
    
    /// Formats x265 `master-display` parameter string (`G(...)B(...)R(...)WP(...)L(max,min)`).
    public var x265MasterDisplayParameter: String? {
        guard let gx = greenX, let gy = greenY,
              let bx = blueX, let by = blueY,
              let rx = redX, let ry = redY,
              let wx = whitePointX, let wy = whitePointY,
              let maxL = maxLuminance, let minL = minLuminance else {
            return nil
        }
        let s = 50000.0
        let ls = 10000.0
        return String(
            format: "G(%.0f,%.0f)B(%.0f,%.0f)R(%.0f,%.0f)WP(%.0f,%.0f)L(%.0f,%.0f)",
            (gx * s).rounded(), (gy * s).rounded(),
            (bx * s).rounded(), (by * s).rounded(),
            (rx * s).rounded(), (ry * s).rounded(),
            (wx * s).rounded(), (wy * s).rounded(),
            (maxL * ls).rounded(), max(1.0, (minL * ls).rounded())
        )
    }
}

public struct HDRContentLightLevel: Hashable, Codable, Sendable {
    public var maxCLL: Int
    public var maxFALL: Int
    
    public init(maxCLL: Int, maxFALL: Int) {
        self.maxCLL = max(0, maxCLL)
        self.maxFALL = max(0, maxFALL)
    }
    
    public var formattedSummary: String {
        "\(maxCLL) / \(maxFALL) nits"
    }
    
    public var x265MaxCLLParameter: String {
        "\(maxCLL),\(maxFALL)"
    }
}

public struct DolbyVisionInfo: Hashable, Codable, Sendable {
    public var profile: Int?
    public var level: Int?
    public var rpuPresent: Bool
    public var blPresent: Bool
    public var elPresent: Bool
    public var blSignalCompatibilityID: Int?
    
    public init(
        profile: Int? = nil,
        level: Int? = nil,
        rpuPresent: Bool = true,
        blPresent: Bool = true,
        elPresent: Bool = false,
        blSignalCompatibilityID: Int? = nil
    ) {
        self.profile = profile
        self.level = level
        self.rpuPresent = rpuPresent
        self.blPresent = blPresent
        self.elPresent = elPresent
        self.blSignalCompatibilityID = blSignalCompatibilityID
    }
    
    public var formattedSummary: String {
        var parts: [String] = []
        if let profile {
            if let compat = blSignalCompatibilityID {
                parts.append("Profile \(profile).\(compat)")
            } else {
                parts.append("Profile \(profile)")
            }
        } else {
            parts.append("Dolby Vision")
        }
        var layers: [String] = []
        if blPresent { layers.append("BL") }
        if elPresent { layers.append("EL") }
        if rpuPresent { layers.append("RPU") }
        if !layers.isEmpty {
            parts.append(layers.joined(separator: "+"))
        }
        return parts.joined(separator: " • ")
    }
    
    public var isProfileFiveToneShifted: Bool {
        profile == 5
    }
}

public struct VideoEncodingConfig: Hashable, Codable, Sendable {
    public var bitrate: String // "auto" or kbps string like "15000k"
    public var frameRate: String? // "24000/1001", "24", "25", "30000/1001", "30", "50", "60000/1001", "60", or nil for Auto
    public var fieldOrder: VideoFieldOrder? // nil / .auto, .progressive, .topFirst, .bottomFirst
    public var colorSpace: VideoColorSpace? // nil / .auto for Original / Auto
    public var profile: String? // H.264: auto/high/main/baseline/constrained_*; HEVC: auto/main/main10/main422/main42210; ProRes: 0..5
    public var entropyMode: VideoEntropyMode? // H.264 only (.auto / .cabac / .cavlc)
    public var keyFrameInterval: Int? // nil = Automatic, or positive GOP frame count
    public var allowFrameReordering: Bool // B-frames / frame reordering (H.264 non-Baseline & HEVC)
    public var preserveAlpha: Bool // Preserve alpha channel (ProRes 4444/XQ & HEVC 8-bit 4:2:0)
    public var multiPass: Bool // H.264 / HEVC 2-pass encoding
    public var rateControlMode: VideoRateControlMode
    public var qualityScale: Int // 1...100 calibrated VideoToolbox quality (default 65 Balanced)
    public var spatialAQ: Bool // Hardware Spatial Adaptive QP (-spatial_aq 1 / kVTCompressionPropertyKey_SpatialAdaptiveQPLevel)
    public var maxBitrate: String? // Optional VBV / DataRateLimits peak ceiling (e.g. "20000k")
    public var deinterlaceMode: VideoDeinterlaceMode // Conditional deinterlacing (.auto / .off / .force)
    public var resizeOption: VideoResizeOption // Optional hardware/software scaling
    public var rotation: VideoRotation // Optional hardware/software rotation & flip
    public var svtPreset: Int? // Optional SVT-AV1 speed preset (-2...13, default 6)
    
    public init(
        bitrate: String = "auto",
        frameRate: String? = nil,
        fieldOrder: VideoFieldOrder? = nil,
        colorSpace: VideoColorSpace? = nil,
        profile: String? = nil,
        entropyMode: VideoEntropyMode? = nil,
        keyFrameInterval: Int? = nil,
        allowFrameReordering: Bool = true,
        preserveAlpha: Bool = false,
        multiPass: Bool = false,
        rateControlMode: VideoRateControlMode? = nil,
        qualityScale: Int = VideoQualityPreset.balanced.qualityValue,
        spatialAQ: Bool = true,
        maxBitrate: String? = nil,
        deinterlaceMode: VideoDeinterlaceMode = .auto,
        resizeOption: VideoResizeOption = .original,
        rotation: VideoRotation = .none,
        svtPreset: Int? = nil
    ) {
        self.bitrate = bitrate
        self.frameRate = frameRate
        self.fieldOrder = fieldOrder
        self.colorSpace = colorSpace
        self.profile = profile
        self.entropyMode = entropyMode
        self.keyFrameInterval = keyFrameInterval
        self.allowFrameReordering = allowFrameReordering
        self.preserveAlpha = preserveAlpha
        
        let trimmedBitrate = bitrate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasExplicitBitrate = !trimmedBitrate.isEmpty && trimmedBitrate != "auto"
        let resolvedRateControl: VideoRateControlMode
        if let rc = rateControlMode {
            resolvedRateControl = rc
        } else if multiPass {
            resolvedRateControl = .twoPassVBR
        } else if hasExplicitBitrate {
            resolvedRateControl = .averageBitrate
        } else {
            resolvedRateControl = .constantQuality
        }
        
        self.rateControlMode = resolvedRateControl
        self.multiPass = multiPass || (resolvedRateControl == .twoPassVBR)
        self.qualityScale = max(1, min(100, qualityScale))
        self.spatialAQ = spatialAQ
        self.maxBitrate = maxBitrate
        self.deinterlaceMode = deinterlaceMode
        self.resizeOption = resizeOption
        self.rotation = rotation
        self.svtPreset = svtPreset
    }
    
    public var effectiveRateControlMode: VideoRateControlMode {
        if multiPass || rateControlMode == .twoPassVBR {
            return .twoPassVBR
        }
        let trimmed = bitrate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rateControlMode == .averageBitrate || (!trimmed.isEmpty && trimmed != "auto") {
            return .averageBitrate
        }
        return .constantQuality
    }
    
    public static func `default`(for action: TrackAction) -> VideoEncodingConfig {
        switch action {
        case .transcodeH264_VT:
            return VideoEncodingConfig(
                bitrate: "auto",
                frameRate: nil,
                fieldOrder: nil,
                colorSpace: nil,
                profile: "auto",
                entropyMode: .auto,
                keyFrameInterval: nil,
                allowFrameReordering: true,
                preserveAlpha: false,
                multiPass: false,
                rateControlMode: .constantQuality,
                qualityScale: VideoQualityPreset.balanced.qualityValue,
                spatialAQ: true,
                maxBitrate: nil,
                deinterlaceMode: .auto,
                resizeOption: .original,
                rotation: .none
            )
        case .transcodeHEVC_VT:
            return VideoEncodingConfig(
                bitrate: "auto",
                frameRate: nil,
                fieldOrder: nil,
                colorSpace: nil,
                profile: "auto",
                entropyMode: nil,
                keyFrameInterval: nil,
                allowFrameReordering: true,
                preserveAlpha: false,
                multiPass: false,
                rateControlMode: .constantQuality,
                qualityScale: VideoQualityPreset.balanced.qualityValue,
                spatialAQ: true,
                maxBitrate: nil,
                deinterlaceMode: .auto,
                resizeOption: .original,
                rotation: .none
            )
        case .transcodeProRes:
            return VideoEncodingConfig(
                bitrate: "auto",
                frameRate: nil,
                fieldOrder: nil,
                colorSpace: nil,
                profile: "auto",
                entropyMode: nil,
                keyFrameInterval: nil,
                allowFrameReordering: true,
                preserveAlpha: false,
                multiPass: false,
                rateControlMode: .constantQuality,
                qualityScale: VideoQualityPreset.balanced.qualityValue,
                spatialAQ: false,
                maxBitrate: nil,
                deinterlaceMode: .auto,
                resizeOption: .original,
                rotation: .none,
                svtPreset: nil
            )
        case .transcodeAV1:
            return VideoEncodingConfig(
                bitrate: "auto",
                frameRate: nil,
                fieldOrder: nil,
                colorSpace: nil,
                profile: "auto",
                entropyMode: nil,
                keyFrameInterval: nil,
                allowFrameReordering: true,
                preserveAlpha: false,
                multiPass: false,
                rateControlMode: .constantQuality,
                qualityScale: VideoQualityPreset.balanced.qualityValue,
                spatialAQ: false,
                maxBitrate: nil,
                deinterlaceMode: .auto,
                resizeOption: .original,
                rotation: .none,
                svtPreset: 6
            )
        case .transcodeUncompressed:
            return VideoEncodingConfig(
                bitrate: "auto",
                frameRate: nil,
                fieldOrder: nil,
                colorSpace: nil,
                profile: "auto",
                entropyMode: nil,
                keyFrameInterval: nil,
                allowFrameReordering: true,
                preserveAlpha: false,
                multiPass: false,
                rateControlMode: .constantQuality,
                qualityScale: VideoQualityPreset.balanced.qualityValue,
                spatialAQ: false,
                maxBitrate: nil,
                deinterlaceMode: .auto,
                resizeOption: .original,
                rotation: .none,
                svtPreset: nil
            )
        default:
            return VideoEncodingConfig()
        }
    }
    
    public mutating func sanitize(for action: TrackAction) {
        qualityScale = max(1, min(100, qualityScale))
        if rateControlMode == .twoPassVBR {
            multiPass = true
        } else if multiPass {
            rateControlMode = .twoPassVBR
        }
        
        switch action {
        case .transcodeH264_VT:
            svtPreset = nil
            let validProfiles = ["auto", "high", "main", "baseline", "constrained_high", "constrained_baseline"]
            if let prof = profile, !validProfiles.contains(prof) {
                profile = "auto"
            } else if profile == nil {
                profile = "auto"
            }
            if profile == "baseline" || profile == "constrained_baseline" {
                if entropyMode == .cabac {
                    entropyMode = .cavlc
                }
            } else if entropyMode == nil {
                entropyMode = .auto
            }
            if !multiPass && (fieldOrder == .topFirst || fieldOrder == .bottomFirst) {
                fieldOrder = nil
            }
            preserveAlpha = false
        case .transcodeHEVC_VT:
            svtPreset = nil
            let validProfiles = ["auto", "main", "main10", "main422", "main42210"]
            if let prof = profile, !validProfiles.contains(prof) {
                profile = "auto"
            } else if profile == nil {
                profile = "auto"
            }
            entropyMode = nil
            if fieldOrder == .topFirst || fieldOrder == .bottomFirst {
                fieldOrder = nil
            }
            let canPreserveAlpha = !multiPass && (profile == "auto" || profile == "main")
            if !canPreserveAlpha {
                preserveAlpha = false
            }
        case .transcodeProRes:
            svtPreset = nil
            let validProfiles = ["auto", "0", "1", "2", "3", "4", "5"]
            if let prof = profile, !validProfiles.contains(prof) {
                profile = "auto"
            } else if profile == nil {
                profile = "auto"
            }
            bitrate = "auto"
            maxBitrate = nil
            entropyMode = nil
            keyFrameInterval = nil
            multiPass = false
            rateControlMode = .constantQuality
            spatialAQ = false
            if profile != "auto" && profile != "4" && profile != "5" {
                preserveAlpha = false
            }
        case .transcodeAV1:
            let validProfiles = ["auto", "8bit", "10bit"]
            if let prof = profile, !validProfiles.contains(prof) {
                profile = "auto"
            } else if profile == nil {
                profile = "auto"
            }
            if let preset = svtPreset {
                svtPreset = max(-2, min(13, preset))
            } else {
                svtPreset = 6
            }
            entropyMode = nil
            if fieldOrder == .topFirst || fieldOrder == .bottomFirst {
                fieldOrder = nil
            }
            if rateControlMode == .twoPassVBR || multiPass {
                rateControlMode = .averageBitrate
                multiPass = false
            }
            spatialAQ = false
            preserveAlpha = false
        case .transcodeUncompressed:
            let validProfiles = ["auto", "8bit_422", "10bit_422"]
            if let prof = profile, !validProfiles.contains(prof) {
                profile = "auto"
            } else if profile == nil {
                profile = "auto"
            }
            svtPreset = nil
            bitrate = "auto"
            maxBitrate = nil
            entropyMode = nil
            keyFrameInterval = nil
            allowFrameReordering = true
            preserveAlpha = false
            multiPass = false
            rateControlMode = .constantQuality
            qualityScale = VideoQualityPreset.balanced.qualityValue
            spatialAQ = false
        default:
            break
        }
    }
}

public struct AudioEncodingConfig: Hashable, Codable, Sendable {
    public var bitrate: String // "128k", "192k", "256k", "320k", "V0", "V2"
    public var sampleRate: String? // "44100", "48000", "96000", or nil for Auto
    public var channels: Int? // 1, 2, 6, or nil for Auto
    public var bitDepth: String? // "16", "24" for ALAC/FLAC
    public var isVBR: Bool
    public var aacMode: AudioAACEncodingMode // AudioToolbox aac_at mode (.vbrQuality / .cbr / .abr / .cvbr)
    public var aacQuality: Int // 0...14 for AudioToolbox VBR (default 2, lower = higher quality)
    public var loudnessTarget: AudioLoudnessTarget // Optional 2-pass EBU R128 loudness normalization
    
    public init(
        bitrate: String = "192k",
        sampleRate: String? = nil,
        channels: Int? = nil,
        bitDepth: String? = nil,
        isVBR: Bool = false,
        aacMode: AudioAACEncodingMode? = nil,
        aacQuality: Int = 2,
        loudnessTarget: AudioLoudnessTarget = .off
    ) {
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.isVBR = isVBR
        self.aacMode = aacMode ?? (isVBR ? .vbrQuality : .cbr)
        self.aacQuality = max(0, min(14, aacQuality))
        self.loudnessTarget = loudnessTarget
    }
    
    public static func `default`(for action: TrackAction) -> AudioEncodingConfig {
        switch action {
        case .transcodeMP3:
            return AudioEncodingConfig(bitrate: "V2", channels: nil, isVBR: true)
        case .transcodeALAC:
            return AudioEncodingConfig(bitrate: "Lossless", channels: nil, bitDepth: nil)
        case .transcodeAAC:
            return AudioEncodingConfig(bitrate: "auto", channels: nil, isVBR: true, aacMode: .vbrQuality, aacQuality: 2)
        case .transcodeAC3_51:
            return AudioEncodingConfig(bitrate: "auto", channels: nil)
        case .transcodeEAC3_51:
            return AudioEncodingConfig(bitrate: "auto", channels: nil)
        case .transcodeOpus:
            return AudioEncodingConfig(bitrate: "auto", channels: nil)
        case .transcodeFLAC:
            return AudioEncodingConfig(bitrate: "Lossless", channels: nil, bitDepth: nil)
        case .transcodeWAV:
            return AudioEncodingConfig(bitrate: "Uncompressed", channels: nil, bitDepth: nil)
        case .transcodeAIFF:
            return AudioEncodingConfig(bitrate: "Uncompressed", channels: nil, bitDepth: nil)
        default:
            return AudioEncodingConfig()
        }
    }
}

public struct MediaTrack: Identifiable, Hashable, Codable, Sendable {
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
    public var rFrameRate: String?
    public var pixelFormat: String?
    public var colorSpace: String?
    public var colorPrimaries: String?
    public var colorTransfer: String?
    public var colorRange: String?
    public var chromaLocation: String?
    public var fieldOrder: String?
    public var sampleAspectRatio: String?
    public var displayAspectRatio: String?
    public var bitDepth: Int?
    public var hasBFrames: Int?
    public var frameCount: Int?
    public var isHDRDolbyVision: Bool
    public var timeBase: String?
    public var masteringDisplay: HDRMasteringDisplay?
    public var contentLightLevel: HDRContentLightLevel?
    public var dolbyVision: DolbyVisionInfo?
    
    // Audio specific
    public var channels: Int?
    public var channelLayout: String?
    public var sampleRate: String?
    public var sampleFormat: String?
    
    // Common
    public var codecTag: String?
    public var codecLevel: Int?
    public var bitRate: Int64?
    public var language: String
    public var title: String
    public var isDefault: Bool
    public var isForced: Bool
    public var dispositionFlags: [String]
    public var tags: [String: String]
    
    // User configuration
    public var isSelected: Bool
    public var action: TrackAction
    public var audioConfig: AudioEncodingConfig
    public var videoConfig: VideoEncodingConfig
    
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
        codecTag: String? = nil,
        codecLevel: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        frameRate: String? = nil,
        rFrameRate: String? = nil,
        pixelFormat: String? = nil,
        colorSpace: String? = nil,
        colorPrimaries: String? = nil,
        colorTransfer: String? = nil,
        colorRange: String? = nil,
        chromaLocation: String? = nil,
        fieldOrder: String? = nil,
        sampleAspectRatio: String? = nil,
        displayAspectRatio: String? = nil,
        bitDepth: Int? = nil,
        hasBFrames: Int? = nil,
        frameCount: Int? = nil,
        isHDRDolbyVision: Bool = false,
        channels: Int? = nil,
        channelLayout: String? = nil,
        sampleRate: String? = nil,
        sampleFormat: String? = nil,
        bitRate: Int64? = nil,
        language: String = "und",
        title: String = "",
        isDefault: Bool = false,
        isForced: Bool = false,
        dispositionFlags: [String] = [],
        tags: [String: String] = [:],
        isSelected: Bool = true,
        action: TrackAction = .copy,
        audioConfig: AudioEncodingConfig? = nil,
        videoConfig: VideoEncodingConfig? = nil,
        isExternal: Bool = false,
        externalURL: URL? = nil,
        timeBase: String? = nil,
        masteringDisplay: HDRMasteringDisplay? = nil,
        contentLightLevel: HDRContentLightLevel? = nil,
        dolbyVision: DolbyVisionInfo? = nil
    ) {
        self.id = id
        self.streamIndex = streamIndex
        self.mediaType = mediaType
        self.codecName = codecName
        self.codecLongName = codecLongName
        self.profile = profile
        self.codecTag = codecTag
        self.codecLevel = codecLevel
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.rFrameRate = rFrameRate
        self.pixelFormat = pixelFormat
        self.colorSpace = colorSpace
        self.colorPrimaries = colorPrimaries
        self.colorTransfer = colorTransfer
        self.colorRange = colorRange
        self.chromaLocation = chromaLocation
        self.fieldOrder = fieldOrder
        self.sampleAspectRatio = sampleAspectRatio
        self.displayAspectRatio = displayAspectRatio
        self.bitDepth = bitDepth
        self.hasBFrames = hasBFrames
        self.frameCount = frameCount
        self.isHDRDolbyVision = isHDRDolbyVision
        self.timeBase = timeBase
        self.masteringDisplay = masteringDisplay
        self.contentLightLevel = contentLightLevel
        self.dolbyVision = dolbyVision
        self.channels = channels
        self.channelLayout = channelLayout
        self.sampleRate = sampleRate
        self.sampleFormat = sampleFormat
        self.bitRate = bitRate
        self.language = language
        self.title = title
        self.isDefault = isDefault
        self.isForced = isForced
        self.dispositionFlags = dispositionFlags
        self.tags = tags
        self.isSelected = isSelected
        self.action = action
        self.audioConfig = audioConfig ?? AudioEncodingConfig.default(for: action)
        self.videoConfig = videoConfig ?? VideoEncodingConfig.default(for: action)
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
    
    public var hasAlphaChannel: Bool {
        let pf = pixelFormat?.lowercased() ?? ""
        return pf.contains("yuva") || pf.contains("rgba") || pf.contains("bgra") || pf.contains("argb") || pf.contains("abgr") || pf.contains("ayuv") || pf.contains("gbrap")
    }
    
    public var dynamicRangeBadge: String? {
        guard mediaType == .video else { return nil }
        if isHDRDolbyVision { return "Dolby Vision" }
        switch colorTransfer?.lowercased() {
        case "smpte2084": return "HDR10 (PQ)"
        case "arib-std-b67": return "HLG (HDR)"
        default: return "SDR"
        }
    }
    
    public var codecLevelDisplay: String? {
        guard let level = codecLevel, level > 0 else { return nil }
        let lower = codecName.lowercased()
        if lower == "hevc" || lower == "h265" {
            let major = level / 30
            let minor = (level % 30) / 3
            return "\(major).\(minor)"
        } else if lower == "h264" || lower == "avc" || lower == "avc1" {
            return String(format: "%.1f", Double(level) / 10.0)
        }
        return "\(level)"
    }
    
    public var chromaSubsamplingDisplay: String? {
        guard let pf = pixelFormat?.lowercased(), !pf.isEmpty else { return nil }
        let sub: String
        if pf.contains("420") || pf.contains("nv12") || pf.contains("nv21") || pf.contains("p010") {
            sub = "4:2:0"
        } else if pf.contains("422") || pf.contains("p210") || pf.contains("yuyv") || pf.contains("uyvy") {
            sub = "4:2:2"
        } else if pf.contains("444") || pf.contains("p410") || pf.contains("yuva444") {
            sub = "4:4:4"
        } else if pf.contains("rgb") || pf.contains("bgr") || pf.contains("argb") || pf.contains("abgr") {
            sub = "RGB"
        } else {
            return pf
        }
        return hasAlphaChannel ? "\(sub) + Alpha" : sub
    }
    
    public var formattedFieldOrder: String? {
        guard let fo = fieldOrder?.lowercased(), !fo.isEmpty, fo != "unknown" else { return nil }
        switch fo {
        case "progressive": return "Progressive"
        case "tt", "tb": return "Interlaced (Top First)"
        case "bb", "bt": return "Interlaced (Bottom First)"
        default: return fo
        }
    }
    
    public var formattedColorSpec: String? {
        let p = colorPrimaries?.lowercased()
        let t = colorTransfer?.lowercased()
        let m = colorSpace?.lowercased()
        
        if p == "bt709" && (t == nil || t == "bt709") && (m == nil || m == "bt709") {
            return "Rec. 709 (1-1-1)"
        } else if p == "bt2020" && t == "smpte2084" {
            return "Rec. 2020 PQ / HDR10 (9-16-9)"
        } else if p == "bt2020" && t == "arib-std-b67" {
            return "Rec. 2020 HLG (9-18-9)"
        } else if p == "bt2020" {
            return "Rec. 2020 (SDR)"
        } else if p == "smpte170m" || m == "smpte170m" {
            return "Rec. 601 NTSC (6-6-6)"
        } else if p == "bt470bg" || m == "bt470bg" {
            return "Rec. 601 PAL (5-5-5)"
        }
        
        let parts = [
            p.map(Self.readableColorToken),
            t.map(Self.readableColorToken),
            m.map(Self.readableColorToken)
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }
    
    private static func readableColorToken(_ raw: String) -> String {
        switch raw {
        case "bt709": return "BT.709"
        case "bt2020": return "BT.2020"
        case "bt2020nc": return "BT.2020 NCL"
        case "bt2020-10": return "BT.2020 10-bit"
        case "bt2020-12": return "BT.2020 12-bit"
        case "smpte2084": return "PQ (ST 2084)"
        case "arib-std-b67": return "HLG"
        case "smpte170m": return "SMPTE 170M"
        case "bt470bg": return "BT.470 BG"
        case "smpte432": return "Display P3"
        case "iec61966-2-1": return "sRGB"
        default: return raw.uppercased()
        }
    }
    
    public var formattedColorRange: String? {
        guard let cr = colorRange?.lowercased(), !cr.isEmpty, cr != "unknown" else { return nil }
        switch cr {
        case "tv", "mpeg": return "Limited (16–235)"
        case "pc", "jpeg": return "Full (0–255)"
        default: return cr
        }
    }
    
    public var formattedBitRate: String? {
        guard let br = bitRate, br > 0 else { return nil }
        return MediaFormatters.formatBitrate(br)
    }
    
    public var formattedSampleRateDisplay: String? {
        guard let sr = sampleRate, let val = Int(sr), val > 0 else { return nil }
        let khz = Double(val) / 1000.0
        return khz.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
    }
    
    public var formattedSampleFormat: String? {
        guard let sf = sampleFormat?.lowercased(), !sf.isEmpty else { return nil }
        switch sf {
        case "fltp", "flt": return "32-bit Float"
        case "dblp", "dbl": return "64-bit Float"
        case "s16p", "s16": return "16-bit PCM"
        case "s24p", "s24": return "24-bit PCM"
        case "s32p", "s32": return "32-bit PCM"
        case "u8p", "u8": return "8-bit PCM"
        default: return sf.uppercased()
        }
    }
    
    public var encoderName: String? {
        tagValue(forKeyCaseInsensitive: "encoder")
    }
    
    public var startTimecode: String? {
        tagValue(forKeyCaseInsensitive: "timecode")
    }
    
    public var isVariableFrameRate: Bool? {
        guard let avg = frameRate, let real = rFrameRate, !avg.isEmpty, !real.isEmpty else { return nil }
        return avg != real
    }
    
    public var isInterlacedSource: Bool {
        guard let fo = fieldOrder?.lowercased() else { return false }
        return fo == "tt" || fo == "bb" || fo == "tb" || fo == "bt"
    }
    
    public var isHEVCCodec: Bool {
        let lower = codecName.lowercased()
        return lower == "hevc" || lower == "h265" || lower == "hev1" || lower == "hvc1"
    }
    
    public var hasHEV1Tag: Bool {
        codecTag?.lowercased() == "hev1"
    }
    
    public var formattedMasteringDisplay: String? {
        masteringDisplay?.formattedSummary
    }
    
    public var formattedContentLightLevel: String? {
        contentLightLevel?.formattedSummary
    }
    
    public var formattedDolbyVision: String? {
        if let dolbyVision {
            return dolbyVision.formattedSummary
        }
        return isHDRDolbyVision ? "Dolby Vision RPU Detected" : nil
    }
    
    public var requiresDolbyVisionToneGuard: Bool {
        guard mediaType == .video && (isHDRDolbyVision || dolbyVision != nil) else { return false }
        if let profile = dolbyVision?.profile {
            return profile == 5 || (profile == 8 && (dolbyVision?.rpuPresent ?? true))
        }
        return true
    }
    
    public var resolvedUncompressedIs10Bit: Bool {
        switch videoConfig.profile?.lowercased() {
        case "10bit_422":
            return true
        case "8bit_422":
            return false
        default:
            if let bd = bitDepth, bd >= 10 {
                return true
            }
            let pfLower = pixelFormat?.lowercased() ?? ""
            let trLower = colorTransfer?.lowercased() ?? ""
            return pfLower.contains("10")
                || pfLower.contains("12")
                || trLower == "smpte2084"
                || trLower == "arib-std-b67"
                || isHDRDolbyVision
        }
    }

    public var resolvedProResProfile: String {
        let validProfiles = ["0", "1", "2", "3", "4", "5"]
        if let prof = videoConfig.profile, validProfiles.contains(prof) {
            return prof
        }
        let pfLower = pixelFormat?.lowercased() ?? ""
        if videoConfig.preserveAlpha || hasAlphaChannel || pfLower.contains("444") || pfLower.contains("p410") {
            return "4"
        }
        return "2"
    }
    
    private func tagValue(forKeyCaseInsensitive target: String) -> String? {
        for (k, v) in tags where k.caseInsensitiveCompare(target) == .orderedSame {
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
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
            case .transcodeProRes, .transcodeUncompressed: return "mov"
            case .transcodeH264_VT, .transcodeHEVC_VT, .transcodeAV1: return "mp4"
            
            // Audio Transcoding
            case .transcodeALAC, .transcodeAAC: return "m4a"
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
