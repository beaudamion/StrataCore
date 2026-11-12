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

public enum VideoExecutionKind: String, Codable, Equatable, Sendable {
    case none
    case losslessCopy
    case hardwareGPU
    case hardwareTwoPass
    case hybrid
    case software
}

public struct ExecutionPlan: Equatable, Sendable {
    public let tier: ExecutionTier
    public let videoKind: VideoExecutionKind
    public let hasAudioEncode: Bool
    public let badgeTitle: String
    public let usesZeroCopyVLD: Bool
    public let usesNativeVideoToolbox: Bool
    public let retagsHEVCToHVC1: Bool
    public let requiresDolbyVisionGuard: Bool
    public let dolbyVisionWarningMessage: String?
    public let plainReasonSummary: String
    public let reasonSummary: String
    
    public init(
        tier: ExecutionTier,
        videoKind: VideoExecutionKind? = nil,
        hasAudioEncode: Bool? = nil,
        badgeTitle: String,
        usesZeroCopyVLD: Bool,
        usesNativeVideoToolbox: Bool,
        retagsHEVCToHVC1: Bool,
        requiresDolbyVisionGuard: Bool,
        dolbyVisionWarningMessage: String?,
        plainReasonSummary: String? = nil,
        reasonSummary: String
    ) {
        self.tier = tier
        let inferredAudioEncode = hasAudioEncode ?? badgeTitle.contains("Audio Encode")
        self.hasAudioEncode = inferredAudioEncode
        if let explicitKind = videoKind {
            self.videoKind = explicitKind
        } else if badgeTitle == "Audio Encode" {
            self.videoKind = .none
        } else if badgeTitle.contains("Native 2-Pass") {
            self.videoKind = .hardwareTwoPass
        } else if badgeTitle.contains("Zero-Copy") {
            self.videoKind = .hardwareGPU
        } else if badgeTitle.contains("Hybrid") {
            self.videoKind = .hybrid
        } else if badgeTitle.contains("Software") {
            self.videoKind = .software
        } else {
            self.videoKind = .losslessCopy
        }
        self.badgeTitle = badgeTitle
        self.usesZeroCopyVLD = usesZeroCopyVLD
        self.usesNativeVideoToolbox = usesNativeVideoToolbox
        self.retagsHEVCToHVC1 = retagsHEVCToHVC1
        self.requiresDolbyVisionGuard = requiresDolbyVisionGuard
        self.dolbyVisionWarningMessage = dolbyVisionWarningMessage
        self.plainReasonSummary = plainReasonSummary ?? reasonSummary
        self.reasonSummary = reasonSummary
    }
    
    public func displayBadgeTitle(showTechnicalDetails: Bool) -> String {
        if showTechnicalDetails {
            return badgeTitle
        }
        let suffix = hasAudioEncode ? " + Audio Encode" : ""
        switch videoKind {
        case .none:
            return hasAudioEncode ? "Audio Encode" : "Lossless Remux"
        case .losslessCopy:
            return "Lossless Remux" + suffix
        case .hardwareGPU:
            return "Hardware Encoding" + suffix
        case .hardwareTwoPass:
            return "Hardware 2-Pass Encoding" + suffix
        case .hybrid:
            return "Hybrid Encoding" + suffix
        case .software:
            return "Software Encoding" + suffix
        }
    }
    
    public func displayReasonSummary(showTechnicalDetails: Bool) -> String {
        showTechnicalDetails ? reasonSummary : plainReasonSummary
    }
}

public enum ExecutionPlanner {
    public static func displayTierLabel(_ rawLabel: String, showTechnicalDetails: Bool) -> String {
        if showTechnicalDetails {
            return rawLabel
        }
        let hasAudio = rawLabel.contains("+ Audio Encode")
        let base = rawLabel
            .replacingOccurrences(of: " + Audio Encode", with: "")
            .trimmingCharacters(in: .whitespaces)
        let suffix = hasAudio ? " + Audio Encode" : ""
        switch base {
        case "Zero-Copy HW":
            return "Hardware Encoding" + suffix
        case "Native 2-Pass HW":
            return "Hardware 2-Pass Encoding" + suffix
        case "Hybrid HW + CPU":
            return "Hybrid Encoding" + suffix
        case "Software libav":
            return "Software Encoding" + suffix
        case "Lossless Remux", "Lossless Smart-Cut", "Video Copy", "Video Copy (hvc1)":
            return "Lossless Remux" + suffix
        case "Audio Transcode + hvc1 Copy":
            return "Lossless Remux + Audio Encode"
        case "Audio Encode":
            return "Audio Encode"
        default:
            return rawLabel
        }
    }
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
            let resolvedProf = track.resolvedProResProfile
            if resolvedProf == "4" || resolvedProf == "5" {
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
        let audioTranscodeTracks = selectedTracks.filter { $0.mediaType == .audio && $0.action.isTranscode }
        let hasAudioEncode = !audioTranscodeTracks.isEmpty
        let hasAnyTranscode = selectedTracks.contains { $0.action.isTranscode }
        let isMP4Like = (options.targetContainer == .mp4 || options.targetContainer == .m4v || options.targetContainer == .mov)
        
        let audioSummaries = formattedAudioSummaries(for: audioTranscodeTracks, binaryCapabilities: binaryCapabilities)
        
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
            let plain = isTrimmed
                ? "Lossless Smart-Cut"
                : (retagsHEVC ? "Lossless Remux (Apple QuickTime Tag)" : "Lossless Remux")
            let reason = retagsHEVC
                ? "Zero-generation stream copy with automatic hev1→hvc1 Apple playback tag"
                : "Zero-generation packet stream copy (no video or audio re-encoding)"
            return ExecutionPlan(
                tier: .losslessRemuxOrSmartCut,
                videoKind: selectedVideos.isEmpty ? VideoExecutionKind.none : .losslessCopy,
                hasAudioEncode: false,
                badgeTitle: badge,
                usesZeroCopyVLD: false,
                usesNativeVideoToolbox: false,
                retagsHEVCToHVC1: retagsHEVC,
                requiresDolbyVisionGuard: false,
                dolbyVisionWarningMessage: nil,
                plainReasonSummary: plain,
                reasonSummary: reason
            )
        }
        
        // Tier B (Native): Swift AVAssetReader + VTCompressionSession 2-Pass HW VBR
        if canUseNativeVideoToolboxTwoPass(for: file, options: options) {
            let video = selectedVideos.first
            let vName = (video?.action == .transcodeHEVC_VT) ? "HEVC" : "H.264"
            return ExecutionPlan(
                tier: .zeroCopyHardwareTranscode,
                videoKind: .hardwareTwoPass,
                hasAudioEncode: false,
                badgeTitle: "Native 2-Pass HW",
                usesZeroCopyVLD: true,
                usesNativeVideoToolbox: true,
                retagsHEVCToHVC1: false,
                requiresDolbyVisionGuard: hasDoViBlock,
                dolbyVisionWarningMessage: doViWarning,
                plainReasonSummary: "Hardware 2-Pass \(vName)",
                reasonSummary: "Native VideoToolbox two-pass VBR (\(vName)) with shared IOSurface pixel buffer pool"
            )
        }
        
        // Check VideoToolbox / Zero-Copy VLD vs Hybrid/Software
        if let video = selectedVideos.first, video.action != .copy {
            let audioSuffix = hasAudioEncode ? " + Audio Encode" : ""
            let plainVideoCodec = plainVideoFormatName(for: video)
            let techVTEncoder: String = {
                switch video.action {
                case .transcodeHEVC_VT: return "hevc_videotoolbox"
                case .transcodeProRes: return "prores_videotoolbox"
                default: return "h264_videotoolbox"
                }
            }()
            let vld = canUseZeroCopyVLD(
                for: video,
                useHardwareAcceleration: options.useHardwareAcceleration,
                pass: nil,
                binaryCapabilities: binaryCapabilities
            )
            if vld {
                let plain = hasAudioEncode
                    ? "Hardware \(plainVideoCodec) + \(audioSummaries.plain)"
                    : "Hardware \(plainVideoCodec)"
                let tech = hasAudioEncode
                    ? "End-to-end GPU IOSurface decode → filter → \(techVTEncoder) (videotoolbox_vld) + \(audioSummaries.tech)"
                    : "End-to-end GPU IOSurface decode → filter → \(techVTEncoder) (videotoolbox_vld)"
                return ExecutionPlan(
                    tier: .zeroCopyHardwareTranscode,
                    videoKind: .hardwareGPU,
                    hasAudioEncode: hasAudioEncode,
                    badgeTitle: "Zero-Copy HW" + audioSuffix,
                    usesZeroCopyVLD: true,
                    usesNativeVideoToolbox: false,
                    retagsHEVCToHVC1: false,
                    requiresDolbyVisionGuard: hasDoViBlock,
                    dolbyVisionWarningMessage: doViWarning,
                    plainReasonSummary: plain,
                    reasonSummary: tech
                )
            }
            
            let isTwoPassVideo = (video.action == .transcodeH264_VT || video.action == .transcodeHEVC_VT)
                && (video.videoConfig.multiPass || video.videoConfig.effectiveRateControlMode == .twoPassVBR)
            let isSoftwareOnlyAction = video.action == .transcodeAV1
                || video.action == .transcodeUncompressed
            let usesSWCodec = !options.useHardwareAcceleration
                || isTwoPassVideo
                || isSoftwareOnlyAction
                || (video.action == .transcodeHEVC_VT && video.videoConfig.profile?.lowercased() == "main422")
            
            let badge = (usesSWCodec ? "Software libav" : "Hybrid HW + CPU") + audioSuffix
            let plainBase: String
            let techBase: String
            if usesSWCodec {
                switch video.action {
                case .transcodeAV1:
                    plainBase = "Software AV1"
                    techBase = "Software SVT-AV1 (libsvtav1) pipeline"
                case .transcodeUncompressed:
                    plainBase = video.resolvedUncompressedIs10Bit ? "Uncompressed 10-Bit 4:2:2" : "Uncompressed 8-Bit 4:2:2"
                    techBase = video.resolvedUncompressedIs10Bit
                        ? "Uncompressed 10-Bit 4:2:2 (v210, yuv422p10le) pipeline"
                        : "Uncompressed 8-Bit 4:2:2 (rawvideo 2vuy) pipeline"
                case .transcodeH264_VT:
                    plainBase = isTwoPassVideo ? "Software 2-Pass H.264" : "Software H.264"
                    techBase = isTwoPassVideo ? "Software x264 (libx264 2-Pass VBR) pipeline" : "Software x264 (libx264) pipeline"
                case .transcodeHEVC_VT:
                    plainBase = isTwoPassVideo ? "Software 2-Pass HEVC" : "Software HEVC"
                    techBase = isTwoPassVideo ? "Software x265 (libx265 2-Pass VBR) pipeline" : "Software x265 (libx265) pipeline"
                case .transcodeProRes:
                    plainBase = "Software Apple ProRes"
                    techBase = "Software ProRes (prores_ks) pipeline"
                default:
                    plainBase = "Software \(plainVideoCodec)"
                    techBase = "Software \(plainVideoCodec) pipeline"
                }
            } else {
                plainBase = "Hardware \(plainVideoCodec)"
                techBase = "Hardware VideoToolbox (\(techVTEncoder)) with CPU pixel/format conversion"
            }
            let plain = hasAudioEncode ? "\(plainBase) + \(audioSummaries.plain)" : plainBase
            let reason = hasAudioEncode ? "\(techBase) + \(audioSummaries.tech)" : techBase
            return ExecutionPlan(
                tier: .hybridOrSoftwareLibav,
                videoKind: usesSWCodec ? .software : .hybrid,
                hasAudioEncode: hasAudioEncode,
                badgeTitle: badge,
                usesZeroCopyVLD: false,
                usesNativeVideoToolbox: false,
                retagsHEVCToHVC1: false,
                requiresDolbyVisionGuard: hasDoViBlock,
                dolbyVisionWarningMessage: doViWarning,
                plainReasonSummary: plain,
                reasonSummary: reason
            )
        }
        
        // Audio/subtitle-only transcode alongside video stream copy (or audio-only source)
        let hasSelectedVideo = !selectedVideos.isEmpty
        let badge: String
        let plain: String
        let reason: String
        if !hasSelectedVideo && hasAudioEncode {
            badge = "Audio Encode"
            plain = "\(audioSummaries.plain) Encode"
            reason = "\(audioSummaries.tech) audio encoding"
        } else if hasAudioEncode {
            badge = retagsHEVC ? "Video Copy (hvc1) + Audio Encode" : "Video Copy + Audio Encode"
            plain = "Lossless Video Copy + \(audioSummaries.plain)"
            reason = retagsHEVC
                ? "Lossless video passthrough (hev1→hvc1) + \(audioSummaries.tech)"
                : "Lossless video passthrough + \(audioSummaries.tech)"
        } else {
            badge = "Lossless Remux"
            plain = "Lossless Remux"
            reason = retagsHEVC
                ? "Zero-generation stream copy with automatic hev1→hvc1 Apple playback tag"
                : "Lossless stream copy with subtitle formatting"
        }
        return ExecutionPlan(
            tier: (hasAudioEncode || !hasSelectedVideo) ? .hybridOrSoftwareLibav : .losslessRemuxOrSmartCut,
            videoKind: hasSelectedVideo ? .losslessCopy : VideoExecutionKind.none,
            hasAudioEncode: hasAudioEncode,
            badgeTitle: badge,
            usesZeroCopyVLD: false,
            usesNativeVideoToolbox: false,
            retagsHEVCToHVC1: retagsHEVC,
            requiresDolbyVisionGuard: false,
            dolbyVisionWarningMessage: nil,
            plainReasonSummary: plain,
            reasonSummary: reason
        )
    }
    
    private static func plainVideoFormatName(for track: MediaTrack) -> String {
        switch track.action {
        case .transcodeH264_VT: return "H.264"
        case .transcodeHEVC_VT: return "HEVC"
        case .transcodeAV1: return "AV1"
        case .transcodeProRes: return "Apple ProRes"
        case .transcodeUncompressed:
            return track.resolvedUncompressedIs10Bit ? "Uncompressed 10-Bit 4:2:2" : "Uncompressed 8-Bit 4:2:2"
        default: return track.action.title
        }
    }
    
    private static func formattedAudioSummaries(
        for audioTracks: [MediaTrack],
        binaryCapabilities: FFmpegBinaryCapabilities
    ) -> (plain: String, tech: String) {
        var plainParts: [String] = []
        var techParts: [String] = []
        for track in audioTracks {
            let p: String
            let t: String
            switch track.action {
            case .transcodeAAC:
                p = "AAC Audio"
                t = binaryCapabilities.supportsAudioToolboxAAC ? "AudioToolbox (aac_at)" : "AAC (aac)"
            case .transcodeMP3:
                p = "MP3 Audio"
                t = "MP3 (libmp3lame)"
            case .transcodeALAC:
                p = "ALAC Audio"
                t = "ALAC (alac)"
            case .transcodeFLAC:
                p = "FLAC Audio"
                t = "FLAC (flac)"
            case .transcodeOpus:
                p = "Opus Audio"
                t = "Opus (libopus)"
            case .transcodeAC3_51:
                p = "AC3 Audio"
                t = "AC3 (ac3)"
            case .transcodeEAC3_51:
                p = "E-AC3 Audio"
                t = "E-AC3 (eac3)"
            case .transcodeWAV:
                p = "WAV Audio"
                t = "WAV PCM"
            case .transcodeAIFF:
                p = "AIFF Audio"
                t = "AIFF PCM"
            default:
                p = "\(track.action.title) Audio"
                t = track.action.title
            }
            if !plainParts.contains(p) { plainParts.append(p) }
            if !techParts.contains(t) { techParts.append(t) }
        }
        return (
            plainParts.isEmpty ? "Audio Encode" : plainParts.joined(separator: " + "),
            techParts.isEmpty ? "Audio encoding" : techParts.joined(separator: " + ")
        )
    }
}
