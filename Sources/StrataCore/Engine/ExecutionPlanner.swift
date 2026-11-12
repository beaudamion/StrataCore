import Foundation

public enum ExecutionTier: String, Codable, Equatable, Sendable {
    case losslessRemuxOrSmartCut = "lossless_remux"
    case zeroCopyHardwareTranscode = "zero_copy_hw"
    case hybridOrSoftwareLibav = "hybrid_sw_libav"
    
    public var displayTitle: String {
        switch self {
        case .losslessRemuxOrSmartCut: return "Lossless Remux"
        case .zeroCopyHardwareTranscode: return "Zero-Copy HW"
        case .hybridOrSoftwareLibav: return "Hybrid / SW libav"
        }
    }
}

public struct ExecutionPlan: Equatable, Sendable {
    public let tier: ExecutionTier
    public let badgeTitle: String
    public let usesZeroCopyVLD: Bool
    public let usesNativeVideoToolbox: Bool
    public let retagsHEVCToHVC1: Bool
    public let requiresDolbyVisionGuard: Bool
    public let dolbyVisionWarningMessage: String?
    public let reasonSummary: String
    
    public init(
        tier: ExecutionTier,
        badgeTitle: String,
        usesZeroCopyVLD: Bool,
        usesNativeVideoToolbox: Bool,
        retagsHEVCToHVC1: Bool,
        requiresDolbyVisionGuard: Bool,
        dolbyVisionWarningMessage: String?,
        reasonSummary: String
    ) {
        self.tier = tier
        self.badgeTitle = badgeTitle
        self.usesZeroCopyVLD = usesZeroCopyVLD
        self.usesNativeVideoToolbox = usesNativeVideoToolbox
        self.retagsHEVCToHVC1 = retagsHEVCToHVC1
        self.requiresDolbyVisionGuard = requiresDolbyVisionGuard
        self.dolbyVisionWarningMessage = dolbyVisionWarningMessage
        self.reasonSummary = reasonSummary
    }
}

public enum ExecutionPlanner {
    private static let hwCompatible8Bit420: Set<String> = ["yuv420p", "nv12", "yuvj420p"]
    private static let hwCompatible10Bit: Set<String> = ["p010le", "yuv420p10le", "p210le", "yuv422p10le"]
    private static let avFoundationReadableContainers: Set<String> = ["mp4", "mov", "m4v", "m4a"]
    
    /// Determines whether a specific video transcode track can stay 100% zero-copy on GPU (`videotoolbox_vld`).
    public static func canUseZeroCopyVLD(
        for track: MediaTrack,
        useHardwareAcceleration: Bool,
        pass: Int? = nil,
        binaryCapabilities: FFmpegBinaryCapabilities = .assumedModernDefaults
    ) -> Bool {
        guard useHardwareAcceleration,
              binaryCapabilities.supportsVideoToolboxVLD,
              !track.isExternal,
              track.mediaType == .video,
              track.action != .copy else {
            return false
        }
        
        let cfg = track.videoConfig
        let isTwoPass = (pass != nil) || cfg.multiPass || (cfg.effectiveRateControlMode == .twoPassVBR)
        if isTwoPass && (track.action == .transcodeH264_VT || track.action == .transcodeHEVC_VT) {
            return false
        }
        
        if cfg.preserveAlpha {
            return false
        }
        
        let prof = cfg.profile?.lowercased()
        switch track.action {
        case .transcodeHEVC_VT:
            if prof == "main422" {
                return false
            }
        case .transcodeProRes:
            // ProRes 4444 / 4444 XQ use 4:4:4 p410/ayuv paths; route ProRes 422 family (0..3) only when VLD compatible
            if prof == "4" || prof == "5" {
                return false
            }
            if cfg.fieldOrder == .topFirst || cfg.fieldOrder == .bottomFirst {
                return false
            }
        case .transcodeH264_VT:
            break
        default:
            return false
        }
        
        // Interlaced field output modes rely on CPU setparams
        if cfg.fieldOrder == .topFirst || cfg.fieldOrder == .bottomFirst {
            return false
        }
        
        // Require explicit HW-compatible pixel format so SW-only 4:4:4 / RGB / 12-bit sources download safely
        let pf = (track.pixelFormat ?? "").lowercased()
        let is8Bit420 = hwCompatible8Bit420.contains(pf)
        let is10Bit = hwCompatible10Bit.contains(pf)
        guard is8Bit420 || is10Bit else {
            return false
        }
        
        // Guard against 8-bit source -> HEVC Main10 / Main42210 under VLD (scale_vt lacks bit-depth conversion)
        if track.action == .transcodeHEVC_VT && (prof == "main10" || prof == "main42210") && is8Bit420 {
            return false
        }
        
        // Guard against H.264 HW encode directly from 10-bit VLD surface
        if track.action == .transcodeH264_VT && is10Bit {
            return false
        }
        
        // Verify required VideoToolbox filters exist in the active binary
        if cfg.resizeOption != .original && !binaryCapabilities.supportsScaleVT {
            return false
        }
        if cfg.rotation != .none && !binaryCapabilities.supportsTransposeVT {
            return false
        }
        let needsDeinterlace = shouldDeinterlace(track: track)
        if needsDeinterlace && !binaryCapabilities.supportsYadifVT {
            return false
        }
        if let cs = cfg.colorSpace, cs != .auto, !binaryCapabilities.supportsScaleVT {
            return false
        }
        
        return true
    }
    
    public static func shouldDeinterlace(track: MediaTrack) -> Bool {
        let cfg = track.videoConfig
        switch cfg.deinterlaceMode {
        case .off:
            return false
        case .force:
            return true
        case .auto:
            if cfg.fieldOrder == .progressive {
                return true
            }
            if cfg.fieldOrder == .topFirst || cfg.fieldOrder == .bottomFirst {
                return false
            }
            return track.isInterlacedSource
        }
    }
    
    /// Checks whether a video track is eligible for Native Swift `AVAssetReader` + `VTCompressionSession` 2-Pass HW VBR.
    public static func canUseNativeVideoToolboxTwoPass(
        for file: MediaFile,
        options: RemuxOptions
    ) -> Bool {
        guard options.useHardwareAcceleration,
              !options.preferSoftwareTwoPass else {
            return false
        }
        
        let isMP4LikeTarget = (options.targetContainer == .mp4 || options.targetContainer == .mov || options.targetContainer == .m4v)
        let sourceExt = file.url.pathExtension.lowercased()
        guard isMP4LikeTarget,
              avFoundationReadableContainers.contains(sourceExt) else {
            return false
        }
        
        let selectedTracks = file.tracks.filter { $0.isSelected }
        let selectedVideos = selectedTracks.filter { $0.mediaType == .video }
        guard selectedVideos.count == 1,
              let video = selectedVideos.first,
              !video.isExternal else {
            return false
        }
        
        guard video.action == .transcodeH264_VT || video.action == .transcodeHEVC_VT else {
            return false
        }
        
        let cfg = video.videoConfig
        guard cfg.effectiveRateControlMode == .twoPassVBR else {
            return false
        }
        
        // Keep SW/FFmpeg filters, alpha, 4:2:2 8-bit, audio transcodes, and subtitles on FFmpeg
        if cfg.profile?.lowercased() == "main422" || cfg.preserveAlpha {
            return false
        }
        if cfg.resizeOption != .original || cfg.rotation != .none || cfg.fieldOrder == .topFirst || cfg.fieldOrder == .bottomFirst {
            return false
        }
        if selectedTracks.contains(where: { $0.mediaType == .subtitle }) {
            return false
        }
        if selectedTracks.contains(where: { $0.mediaType == .audio && ($0.isExternal || $0.action != .copy || $0.audioConfig.loudnessTarget != .off) }) {
            return false
        }
        
        return true
    }
    
    /// Plans the three-tier execution route for a probed `MediaFile` + `RemuxOptions`.
    public static func plan(
        for file: MediaFile,
        options: RemuxOptions,
        binaryCapabilities: FFmpegBinaryCapabilities = .assumedModernDefaults
    ) -> ExecutionPlan {
        let selectedTracks = file.tracks.filter { $0.isSelected }
        let selectedVideos = selectedTracks.filter { $0.mediaType == .video }
        let hasAnyTranscode = selectedTracks.contains { $0.action.isTranscode }
        let isMP4Like = (options.targetContainer == .mp4 || options.targetContainer == .m4v || options.targetContainer == .mov)
        
        let retagsHEVC = isMP4Like && selectedVideos.contains {
            $0.action == .copy && $0.isHEVCCodec && $0.hasHEV1Tag
        }
        
        let guardedTrack = selectedVideos.first {
            $0.action != .copy && $0.requiresDolbyVisionToneGuard
        }
        let hasDoViBlock = (guardedTrack != nil) && !options.allowDolbyVisionReencode
        let doViWarning: String? = guardedTrack.map { tr in
            let profileText = tr.dolbyVision?.profile.map { "Profile \($0)" } ?? "Dolby Vision RPU"
            return "Source contains \(profileText) dynamic metadata. Transcoding discards RPU mastering metadata and may shift colors/brightness unless explicitly confirmed."
        }
        
        // Tier A: Lossless Remux / Smart-Cut
        if !hasAnyTranscode {
            let isTrimmed = options.trimRange?.isValid == true
            let badge = isTrimmed ? "Lossless Smart-Cut" : "Lossless Remux"
            let reason = retagsHEVC
                ? "Zero-generation stream copy with automatic hev1→hvc1 Apple playback tag"
                : "Zero-generation packet stream copy (no video or audio re-encoding)"
            return ExecutionPlan(
                tier: .losslessRemuxOrSmartCut,
                badgeTitle: badge,
                usesZeroCopyVLD: false,
                usesNativeVideoToolbox: false,
                retagsHEVCToHVC1: retagsHEVC,
                requiresDolbyVisionGuard: false,
                dolbyVisionWarningMessage: nil,
                reasonSummary: reason
            )
        }
        
        // Tier B (Native): Swift AVAssetReader + VTCompressionSession 2-Pass HW VBR
        if canUseNativeVideoToolboxTwoPass(for: file, options: options) {
            return ExecutionPlan(
                tier: .zeroCopyHardwareTranscode,
                badgeTitle: "Native 2-Pass HW",
                usesZeroCopyVLD: true,
                usesNativeVideoToolbox: true,
                retagsHEVCToHVC1: false,
                requiresDolbyVisionGuard: hasDoViBlock,
                dolbyVisionWarningMessage: doViWarning,
                reasonSummary: "Native VideoToolbox two-pass VBR with shared IOSurface pixel buffer pool"
            )
        }
        
        // Check VideoToolbox / Zero-Copy VLD vs Hybrid/Software
        if let video = selectedVideos.first, video.action != .copy {
            let vld = canUseZeroCopyVLD(
                for: video,
                useHardwareAcceleration: options.useHardwareAcceleration,
                pass: nil,
                binaryCapabilities: binaryCapabilities
            )
            if vld {
                return ExecutionPlan(
                    tier: .zeroCopyHardwareTranscode,
                    badgeTitle: "Zero-Copy HW",
                    usesZeroCopyVLD: true,
                    usesNativeVideoToolbox: false,
                    retagsHEVCToHVC1: false,
                    requiresDolbyVisionGuard: hasDoViBlock,
                    dolbyVisionWarningMessage: doViWarning,
                    reasonSummary: "End-to-end GPU IOSurface decode → filter → VideoToolbox encode (videotoolbox_vld)"
                )
            }
            
            let usesSWCodec = !options.useHardwareAcceleration
                || video.videoConfig.multiPass
                || (video.videoConfig.effectiveRateControlMode == .twoPassVBR)
                || (video.action == .transcodeHEVC_VT && video.videoConfig.profile?.lowercased() == "main422")
            
            let badge = usesSWCodec ? "Software libav" : "Hybrid HW + CPU"
            let reason = usesSWCodec
                ? "Software libx264/libx265/prores_ks pipeline"
                : "Hardware VideoToolbox encoder with CPU pixel/format conversion"
            return ExecutionPlan(
                tier: .hybridOrSoftwareLibav,
                badgeTitle: badge,
                usesZeroCopyVLD: false,
                usesNativeVideoToolbox: false,
                retagsHEVCToHVC1: false,
                requiresDolbyVisionGuard: hasDoViBlock,
                dolbyVisionWarningMessage: doViWarning,
                reasonSummary: reason
            )
        }
        
        // Audio/subtitle-only transcode alongside video stream copy
        return ExecutionPlan(
            tier: .hybridOrSoftwareLibav,
            badgeTitle: retagsHEVC ? "Audio Transcode + hvc1 Copy" : "Video Copy + Audio Encode",
            usesZeroCopyVLD: false,
            usesNativeVideoToolbox: false,
            retagsHEVCToHVC1: retagsHEVC,
            requiresDolbyVisionGuard: false,
            dolbyVisionWarningMessage: nil,
            reasonSummary: "Lossless video passthrough paired with AudioToolbox / libav audio encoding"
        )
    }
}
