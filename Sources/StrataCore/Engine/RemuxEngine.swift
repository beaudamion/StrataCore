import Foundation

public struct LoudnormMeasurement: Equatable, Codable, Sendable {
    public let inputI: Double
    public let inputTP: Double
    public let inputLRA: Double
    public let inputThresh: Double
    public let targetOffset: Double
    
    public init(
        inputI: Double,
        inputTP: Double,
        inputLRA: Double,
        inputThresh: Double,
        targetOffset: Double
    ) {
        self.inputI = inputI
        self.inputTP = inputTP
        self.inputLRA = inputLRA
        self.inputThresh = inputThresh
        self.targetOffset = targetOffset
    }
}

public enum RemuxError: LocalizedError {
    case ffmpegNotFound
    case noTracksSelected
    case unsafeDolbyVisionReencode(String)
    case executionFailed(String)
    case cancelled
    
    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "ffmpeg binary not found. Please bundle static binaries or check configuration."
        case .noTracksSelected:
            return "Please select at least one video, audio, or subtitle track to multiplex."
        case .unsafeDolbyVisionReencode(let msg):
            return msg
        case .executionFailed(let msg):
            return "Remuxing failed: \(msg)"
        case .cancelled:
            return "Process was cancelled."
        }
    }
}

public actor RemuxEngine {
    private let coordinator: HardwareSessionCoordinator
    private var activeProcesses: [UUID: Process] = [:]
    private var activeNativeEngine: NativeVideoToolboxEngine?
    private var isCancelled: Bool = false
    
    public init(coordinator: HardwareSessionCoordinator = .shared) {
        self.coordinator = coordinator
    }
    
    private func setActiveNativeEngine(_ engine: NativeVideoToolboxEngine?) {
        self.activeNativeEngine = engine
    }
    
    private func registerProcess(_ process: Process, id: UUID) {
        activeProcesses[id] = process
    }
    
    private func unregisterProcess(id: UUID) {
        activeProcesses.removeValue(forKey: id)
    }
    
    /// Validates that the planned execution graph does not violate Dolby Vision RPU safety rules.
    public static func validateExecution(
        for file: MediaFile,
        options: RemuxOptions,
        binaryCapabilities: FFmpegBinaryCapabilities = .assumedModernDefaults
    ) throws {
        let plan = ExecutionPlanner.plan(for: file, options: options, binaryCapabilities: binaryCapabilities)
        if plan.requiresDolbyVisionGuard, let message = plan.dolbyVisionWarningMessage {
            throw RemuxError.unsafeDolbyVisionReencode(message)
        }
    }
    
    /// Builds ffmpeg arguments array based on MediaFile, RemuxOptions, and selected tracks.
    public static func buildArguments(
        for file: MediaFile,
        options: RemuxOptions,
        pass: Int? = nil,
        passLogBaseURL: URL? = nil,
        binaryCapabilities: FFmpegBinaryCapabilities = .assumedModernDefaults,
        loudnessMeasurements: [UUID: LoudnormMeasurement] = [:]
    ) throws -> [String] {
        let selectedTracks = file.tracks.filter { $0.isSelected }
        guard !selectedTracks.isEmpty else {
            throw RemuxError.noTracksSelected
        }
        
        let isPass1 = (pass == 1)
        let activeTracks = isPass1 ? selectedTracks.filter { $0.mediaType == .video } : selectedTracks
        
        var args: [String] = ["-y", "-hide_banner"]
        
        // Input 0: Primary source file (enable VideoToolbox hardware decode & zero-copy VLD when eligible)
        let primaryTranscodeVideos = activeTracks.filter {
            !$0.isExternal && $0.mediaType == .video && $0.action != .copy
        }
        if options.useHardwareAcceleration, !primaryTranscodeVideos.isEmpty {
            let allZeroCopyVLD = primaryTranscodeVideos.allSatisfy {
                ExecutionPlanner.canUseZeroCopyVLD(
                    for: $0,
                    useHardwareAcceleration: options.useHardwareAcceleration,
                    pass: pass,
                    binaryCapabilities: binaryCapabilities
                )
            }
            if allZeroCopyVLD {
                args += ["-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld"]
            } else {
                args += ["-hwaccel", "videotoolbox"]
            }
        }
        args += ["-i", file.url.path]
        
        // Extra inputs: External subtitle, audio, or video files
        var externalInputMap: [URL: Int] = [:]
        var nextInputIndex = 1
        
        for track in activeTracks where track.isExternal {
            if let extURL = track.externalURL {
                if externalInputMap[extURL] == nil {
                    externalInputMap[extURL] = nextInputIndex
                    nextInputIndex += 1
                    let externalNeedsHWDecode = options.useHardwareAcceleration && activeTracks.contains {
                        $0.isExternal && $0.externalURL == extURL && $0.mediaType == .video && $0.action != .copy
                    }
                    if externalNeedsHWDecode {
                        args += ["-hwaccel", "videotoolbox"]
                    }
                    args += ["-i", extURL.path]
                }
            }
        }
        
        // Map streams
        for track in activeTracks {
            if track.isExternal, let extURL = track.externalURL, let inputIdx = externalInputMap[extURL] {
                args += ["-map", "\(inputIdx):\(track.streamIndex)"]
            } else {
                args += ["-map", "0:\(track.streamIndex)"]
            }
        }
        
        // Configure codecs per output stream type
        var videoOutIdx = 0
        var audioOutIdx = 0
        var subtitleOutIdx = 0
        var totalOutIdx = 0
        
        let isMP4Like = (options.targetContainer == .mp4 || options.targetContainer == .m4v || options.targetContainer == .mov)
        
        for track in activeTracks {
            switch track.mediaType {
            case .video:
                args += videoEncoderArguments(
                    for: track,
                    streamSpecifier: ":v:\(videoOutIdx)",
                    isMP4Like: isMP4Like,
                    pass: pass,
                    passLogBaseURL: passLogBaseURL,
                    useHardwareAcceleration: options.useHardwareAcceleration,
                    binaryCapabilities: binaryCapabilities
                )
                videoOutIdx += 1
                
            case .audio:
                args += audioEncoderArguments(
                    for: track,
                    streamSpecifier: ":a:\(audioOutIdx)",
                    binaryCapabilities: binaryCapabilities,
                    loudnessMeasurement: loudnessMeasurements[track.id]
                )
                audioOutIdx += 1
                
            case .subtitle:
                if isMP4Like {
                    // MP4 container requires mov_text for soft subtitles
                    args += ["-c:s:\(subtitleOutIdx)", "mov_text"]
                } else {
                    switch track.action {
                    case .copy:
                        args += ["-c:s:\(subtitleOutIdx)", "copy"]
                    case .transcodeSRT:
                        args += ["-c:s:\(subtitleOutIdx)", "subrip"]
                    case .transcodeMovText:
                        args += ["-c:s:\(subtitleOutIdx)", "mov_text"]
                    default:
                        args += ["-c:s:\(subtitleOutIdx)", "copy"]
                    }
                }
                subtitleOutIdx += 1
                
            default:
                break
            }
            
            if !isPass1 {
                // Set track language & title metadata
                if !track.language.isEmpty && track.language != "und" {
                    args += ["-metadata:s:\(totalOutIdx)", "language=\(track.language)"]
                }
                if !track.title.isEmpty {
                    args += ["-metadata:s:\(totalOutIdx)", "title=\(track.title)"]
                }
                
                // Disposition
                if track.isDefault {
                    args += ["-disposition:s:\(totalOutIdx)", "default"]
                } else if track.isForced {
                    args += ["-disposition:s:\(totalOutIdx)", "forced"]
                }
            }
            
            totalOutIdx += 1
        }
        
        if isPass1 {
            args += ["-an", "-sn", "-dn", "-f", "null", "-"]
            return args
        }
        
        // Metadata Stripping
        if options.stripAllMetadata {
            args += ["-map_metadata", "-1"]
        }
        if options.stripChapters {
            args += ["-map_chapters", "-1"]
        }
        
        // FastStart (moov atom before mdat) & QuickTime colr atom preservation for uncompressed MOV
        var movFlags: [String] = []
        if isMP4Like && options.fastStart {
            movFlags.append("+faststart")
        }
        if options.targetContainer == .mov && activeTracks.contains(where: {
            $0.mediaType == .video && ($0.action == .transcodeUncompressed8 || $0.action == .transcodeUncompressed10)
        }) {
            movFlags.append("+write_colr")
        }
        if !movFlags.isEmpty {
            args += ["-movflags", movFlags.joined()]
        }
        
        // Destination Output File
        args.append(options.outputURL.path)
        
        return args
    }
    
    /// Builds ffmpeg arguments for extracting (or transcoding+extracting) a single track.
    public static func buildTrackExtractionArguments(
        file: MediaFile,
        track: MediaTrack,
        outputURL: URL,
        pass: Int? = nil,
        passLogBaseURL: URL? = nil,
        useHardwareAcceleration: Bool = true,
        binaryCapabilities: FFmpegBinaryCapabilities = .assumedModernDefaults,
        loudnessMeasurement: LoudnormMeasurement? = nil
    ) -> [String] {
        var args = ["-y", "-hide_banner"]
        
        if useHardwareAcceleration && track.mediaType == .video && track.action != .copy {
            let usesVLD = ExecutionPlanner.canUseZeroCopyVLD(
                for: track,
                useHardwareAcceleration: useHardwareAcceleration,
                pass: pass,
                binaryCapabilities: binaryCapabilities
            )
            if usesVLD {
                args += ["-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld"]
            } else {
                args += ["-hwaccel", "videotoolbox"]
            }
        }
        
        if track.isExternal, let extURL = track.externalURL {
            args += ["-i", extURL.path, "-map", "0:\(track.streamIndex)"]
        } else {
            args += ["-i", file.url.path, "-map", "0:\(track.streamIndex)"]
        }
        
        let ext = outputURL.pathExtension.lowercased()
        let isMP4Like = (ext == "m4a" || ext == "mp4" || ext == "mov" || ext == "m4v")
        
        switch track.mediaType {
        case .video:
            args += videoEncoderArguments(
                for: track,
                streamSpecifier: ":v:0",
                isMP4Like: isMP4Like,
                pass: pass,
                passLogBaseURL: passLogBaseURL,
                useHardwareAcceleration: useHardwareAcceleration,
                binaryCapabilities: binaryCapabilities
            )
        case .audio:
            args += audioEncoderArguments(
                for: track,
                streamSpecifier: ":a:0",
                binaryCapabilities: binaryCapabilities,
                loudnessMeasurement: loudnessMeasurement
            )
        case .subtitle:
            switch track.action {
            case .transcodeSRT:
                args += ["-c:s:0", "subrip"]
            case .transcodeMovText:
                args += ["-c:s:0", "mov_text"]
            default:
                args += ["-c:s:0", "copy"]
            }
        default:
            args += ["-c", "copy"]
        }
        
        if pass == 1 {
            args += ["-an", "-sn", "-dn", "-f", "null", "-"]
            return args
        }
        
        if isMP4Like {
            var movFlags = "+faststart"
            if ext == "mov" && (track.action == .transcodeUncompressed8 || track.action == .transcodeUncompressed10) {
                movFlags += "+write_colr"
            }
            args += ["-movflags", movFlags]
        }
        
        args.append(outputURL.path)
        return args
    }
    
    // MARK: - Private Encoder Argument Helpers
    
    private static func normalizedBitrate(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed != "auto" else { return nil }
        if trimmed.hasSuffix("k") || trimmed.hasSuffix("m") {
            return trimmed
        }
        if let val = Int(trimmed), val > 0 {
            return "\(val)k"
        }
        return trimmed
    }
    
    private static func resolvedMultiPassBitrate(for track: MediaTrack) -> String {
        if let explicit = normalizedBitrate(track.videoConfig.bitrate) {
            return explicit
        }
        if let sourceBitRate = track.bitRate, sourceBitRate >= 500_000 {
            return "\(Int(sourceBitRate / 1000))k"
        }
        let width = track.width ?? 1920
        let height = track.height ?? 1080
        let isHEVC = (track.action == .transcodeHEVC_VT)
        if width >= 3840 || height >= 2160 {
            return isHEVC ? "15000k" : "25000k"
        } else if width >= 2560 || height >= 1440 {
            return isHEVC ? "10000k" : "15000k"
        } else if width >= 1900 || height >= 1000 {
            return isHEVC ? "6000k" : "8000k"
        } else if width >= 1200 || height >= 700 {
            return isHEVC ? "3500k" : "5000k"
        } else {
            return isHEVC ? "1800k" : "2500k"
        }
    }
    
    private static func parseBitrateBps(_ raw: String) -> Int? {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty, lower != "auto" else { return nil }
        if lower.hasSuffix("m"), let val = Double(lower.dropLast()), val > 0 {
            return Int((val * 1_000_000.0).rounded())
        }
        if lower.hasSuffix("k"), let val = Double(lower.dropLast()), val > 0 {
            return Int((val * 1000.0).rounded())
        }
        if let val = Double(lower), val > 0 {
            return Int((val * 1000.0).rounded())
        }
        return nil
    }
    
    private static func mappedSoftwareCRF(for qualityScale: Int) -> Int {
        let clamped = max(1, min(100, qualityScale))
        // Maps 55->25, 65->22, 72->20, 80->17
        return max(14, min(32, Int((43.0 - Double(clamped) * 0.32).rounded())))
    }
    
    private static func mappedSVTAV1CRF(for qualityScale: Int) -> Int {
        let clamped = max(1, min(100, qualityScale))
        // Maps 55->34 (Compact), 65->29 (Balanced), 72->26 (High), 80->22 (Master)
        return max(12, min(52, Int((60.5 - Double(clamped) * 0.48).rounded())))
    }
    
    private static func doubleBitrateBufsize(from bitrate: String) -> String? {
        let lower = bitrate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasSuffix("k"), let val = Int(lower.dropLast()), val > 0 {
            return "\(val * 2)k"
        }
        if lower.hasSuffix("m"), let val = Double(lower.dropLast()), val > 0 {
            return "\(Int((val * 2000.0).rounded()))k"
        }
        if let val = Int(lower), val > 0 {
            return "\(val * 2)k"
        }
        return nil
    }
    
    private static func resolvedOutputColorSpec(
        for track: MediaTrack,
        config: VideoEncodingConfig
    ) -> (primaries: String?, transfer: String?, matrix: String?) {
        if let cs = config.colorSpace, cs != .auto {
            return (cs.ffPrimaries, cs.ffTransfer, cs.ffMatrix)
        }
        return (track.colorPrimaries, track.colorTransfer, track.colorSpace)
    }
    
    private static func videoEncoderArguments(
        for track: MediaTrack,
        streamSpecifier spec: String,
        isMP4Like: Bool,
        pass: Int?,
        passLogBaseURL: URL?,
        useHardwareAcceleration: Bool,
        binaryCapabilities: FFmpegBinaryCapabilities = .assumedModernDefaults
    ) -> [String] {
        guard track.action != .copy else {
            if isMP4Like && track.isHEVCCodec && track.hasHEV1Tag {
                return ["-c\(spec)", "copy", "-tag\(spec)", "hvc1"]
            }
            return ["-c\(spec)", "copy"]
        }
        
        let cfg = track.videoConfig
        var args: [String] = []
        let rcMode = cfg.effectiveRateControlMode
        let useTwoPassEncoder = (pass != nil || rcMode == .twoPassVBR) && (track.action == .transcodeH264_VT || track.action == .transcodeHEVC_VT)
        let safeSpecTag = spec.replacingOccurrences(of: ":", with: "_")
        let pfLower = track.pixelFormat?.lowercased() ?? ""
        let hasAlpha = pfLower.contains("yuva") || pfLower.contains("rgba") || pfLower.contains("bgra") || pfLower.contains("argb") || pfLower.contains("abgr") || pfLower.contains("ayuv") || pfLower.contains("gbrap")
        
        let usesVLD = ExecutionPlanner.canUseZeroCopyVLD(
            for: track,
            useHardwareAcceleration: useHardwareAcceleration,
            pass: pass,
            binaryCapabilities: binaryCapabilities
        )
        let needsDeinterlace = ExecutionPlanner.shouldDeinterlace(track: track)
        
        var filterParts: [String] = []
        var setparamsParts: [String] = []
        
        switch track.action {
        case .transcodeH264_VT:
            let validProfiles = ["baseline", "constrained_baseline", "main", "high", "constrained_high", "extended"]
            let rawProfile = cfg.profile?.lowercased()
            let validProf = rawProfile.flatMap { validProfiles.contains($0) ? $0 : nil }
            let useX264 = useTwoPassEncoder || !useHardwareAcceleration
            let isBaseline: Bool
            
            if useX264 {
                args += ["-c\(spec)", "libx264"]
                let x264Profile: String?
                switch validProf {
                case "constrained_baseline", "baseline":
                    x264Profile = "baseline"
                case "constrained_high", "high":
                    x264Profile = "high"
                case "main":
                    x264Profile = "main"
                default:
                    x264Profile = nil
                }
                if let p = x264Profile {
                    args += ["-profile\(spec)", p]
                }
                
                isBaseline = (x264Profile == "baseline")
                if let entropy = cfg.entropyMode, entropy != .auto {
                    let coder = (isBaseline && entropy == .cabac) ? "cavlc" : entropy.rawValue
                    args += ["-coder\(spec)", coder]
                }
                
                if isBaseline || !cfg.allowFrameReordering {
                    args += ["-bf\(spec)", "0"]
                }
                
                args += ["-pix_fmt\(spec)", "yuv420p"]
                if useTwoPassEncoder {
                    let targetBr = resolvedMultiPassBitrate(for: track)
                    args += ["-b\(spec)", targetBr]
                    if let maxBr = cfg.maxBitrate.flatMap({ normalizedBitrate($0) }) {
                        args += ["-maxrate\(spec)", maxBr]
                        if let buf = doubleBitrateBufsize(from: maxBr) {
                            args += ["-bufsize\(spec)", buf]
                        }
                    }
                } else if rcMode == .averageBitrate {
                    let br = normalizedBitrate(cfg.bitrate) ?? resolvedMultiPassBitrate(for: track)
                    args += ["-b\(spec)", br]
                    if let maxBr = cfg.maxBitrate.flatMap({ normalizedBitrate($0) }) {
                        args += ["-maxrate\(spec)", maxBr]
                        if let buf = doubleBitrateBufsize(from: maxBr) {
                            args += ["-bufsize\(spec)", buf]
                        }
                    }
                } else {
                    args += ["-crf\(spec)", "\(mappedSoftwareCRF(for: cfg.qualityScale))"]
                }
                
                if let kf = cfg.keyFrameInterval, kf > 0 {
                    args += ["-g\(spec)", "\(kf)"]
                }
                
                if needsDeinterlace {
                    filterParts.append("yadif=0:-1:1")
                }
                if let rotCPU = cfg.rotation.cpuFilterExpression {
                    filterParts.append(rotCPU)
                }
                if let targetW = cfg.resizeOption.targetWidth {
                    filterParts.append("scale=\(targetW):-2:flags=lanczos")
                }
                
                if !isBaseline {
                    switch cfg.fieldOrder {
                    case .topFirst:
                        args += ["-flags\(spec)", "+ilme+ildct", "-field_order\(spec)", "tt", "-x264-params\(spec)", "tff=1"]
                        setparamsParts.append("field_mode=tff")
                    case .bottomFirst:
                        args += ["-flags\(spec)", "+ilme+ildct", "-field_order\(spec)", "bb", "-x264-params\(spec)", "bff=1"]
                        setparamsParts.append("field_mode=bff")
                    case .progressive:
                        setparamsParts.append("field_mode=prog")
                        args += ["-field_order\(spec)", "progressive"]
                    case .auto, .none:
                        break
                    }
                } else {
                    setparamsParts.append("field_mode=prog")
                    args += ["-field_order\(spec)", "progressive"]
                }
                
                if let p = pass, (p == 1 || p == 2) {
                    args += ["-pass\(spec)", "\(p)"]
                    if let baseURL = passLogBaseURL {
                        let logFile = baseURL.appendingPathComponent("x264\(safeSpecTag)").path
                        args += ["-passlogfile\(spec)", logFile]
                    }
                }
            } else {
                args += ["-c\(spec)", "h264_videotoolbox"]
                if let p = validProf {
                    args += ["-profile\(spec)", p]
                }
                isBaseline = (validProf == "baseline" || validProf == "constrained_baseline")
                if let entropy = cfg.entropyMode, entropy != .auto {
                    let coder = (isBaseline && entropy == .cabac) ? "cavlc" : entropy.rawValue
                    args += ["-coder\(spec)", coder]
                }
                if isBaseline || !cfg.allowFrameReordering {
                    args += ["-bf\(spec)", "0"]
                } else {
                    args += ["-bf\(spec)", "2"]
                }
                if !usesVLD {
                    args += ["-pix_fmt\(spec)", "yuv420p"]
                }
                args += ["-allow_sw\(spec)", "1"]
                if binaryCapabilities.h264VTSupportsRealtime {
                    args += ["-realtime\(spec)", "0"]
                }
                if cfg.spatialAQ && binaryCapabilities.h264VTSupportsSpatialAQ {
                    args += ["-spatial_aq\(spec)", "1"]
                }
                
                if rcMode == .averageBitrate {
                    let br = normalizedBitrate(cfg.bitrate) ?? resolvedMultiPassBitrate(for: track)
                    args += ["-b\(spec)", br]
                    if let maxBr = cfg.maxBitrate.flatMap({ normalizedBitrate($0) }) {
                        args += ["-maxrate\(spec)", maxBr]
                        if let buf = doubleBitrateBufsize(from: maxBr) {
                            args += ["-bufsize\(spec)", buf]
                        }
                    }
                } else {
                    args += ["-q\(spec)", "\(cfg.qualityScale)"]
                }
                if let kf = cfg.keyFrameInterval, kf > 0 {
                    args += ["-g\(spec)", "\(kf)"]
                }
                
                if !usesVLD {
                    if needsDeinterlace {
                        filterParts.append("yadif=0:-1:1")
                    }
                    if let rotCPU = cfg.rotation.cpuFilterExpression {
                        filterParts.append(rotCPU)
                    }
                    if let targetW = cfg.resizeOption.targetWidth {
                        filterParts.append("scale=\(targetW):-2:flags=lanczos")
                    }
                    setparamsParts.append("field_mode=prog")
                    args += ["-field_order\(spec)", "progressive"]
                }
            }
            
        case .transcodeHEVC_VT:
            let validProfiles = ["main", "main10", "main422", "main42210"]
            let rawProfile = cfg.profile?.lowercased()
            let validProf = rawProfile.flatMap { validProfiles.contains($0) ? $0 : nil }
            let useX265 = useTwoPassEncoder || (validProf == "main422") || !useHardwareAcceleration
            
            if useX265 {
                args += ["-c\(spec)", "libx265"]
                switch validProf {
                case "main422":
                    args += ["-pix_fmt\(spec)", "yuv422p"]
                case "main10":
                    args += ["-profile\(spec)", "main10", "-pix_fmt\(spec)", "yuv420p10le"]
                case "main42210":
                    args += ["-profile\(spec)", "main422-10", "-pix_fmt\(spec)", "yuv422p10le"]
                case "main":
                    args += ["-profile\(spec)", "main", "-pix_fmt\(spec)", "yuv420p"]
                default:
                    let sourceIs10Bit = pfLower.contains("10")
                    args += ["-pix_fmt\(spec)", sourceIs10Bit ? "yuv420p10le" : "yuv420p"]
                }
                
                if !cfg.allowFrameReordering {
                    args += ["-bf\(spec)", "0"]
                }
                
                if useTwoPassEncoder {
                    let targetBr = resolvedMultiPassBitrate(for: track)
                    args += ["-b\(spec)", targetBr]
                } else if rcMode == .averageBitrate {
                    let br = normalizedBitrate(cfg.bitrate) ?? resolvedMultiPassBitrate(for: track)
                    args += ["-b\(spec)", br]
                } else {
                    args += ["-crf\(spec)", "\(mappedSoftwareCRF(for: cfg.qualityScale))"]
                }
                
                if let kf = cfg.keyFrameInterval, kf > 0 {
                    args += ["-g\(spec)", "\(kf)"]
                }
                
                if needsDeinterlace {
                    filterParts.append("yadif=0:-1:1")
                }
                if let rotCPU = cfg.rotation.cpuFilterExpression {
                    filterParts.append(rotCPU)
                }
                if let targetW = cfg.resizeOption.targetWidth {
                    filterParts.append("scale=\(targetW):-2:flags=lanczos")
                }
                setparamsParts.append("field_mode=prog")
                args += ["-field_order\(spec)", "progressive"]
                
                var x265Params: [String] = []
                if let p = pass, (p == 1 || p == 2) {
                    x265Params.append("pass=\(p)")
                    if let baseURL = passLogBaseURL {
                        let statsFile = baseURL.appendingPathComponent("x265\(safeSpecTag).log").path
                        x265Params.append("stats=\(statsFile)")
                    }
                }
                if let md = track.masteringDisplay?.x265MasterDisplayParameter {
                    x265Params.append("master-display=\(md)")
                }
                if let cll = track.contentLightLevel?.x265MaxCLLParameter {
                    x265Params.append("max-cll=\(cll)")
                }
                if !x265Params.isEmpty {
                    args += ["-x265-params\(spec)", x265Params.joined(separator: ":")]
                }
            } else {
                args += ["-c\(spec)", "hevc_videotoolbox"]
                let alphaEligible = (validProf == nil || validProf == "main") && cfg.preserveAlpha && hasAlpha
                
                if usesVLD {
                    if let prof = validProf {
                        args += ["-profile\(spec)", prof]
                    } else if pfLower.contains("10") {
                        args += ["-profile\(spec)", "main10"]
                    }
                } else if alphaEligible {
                    if validProf == "main" {
                        args += ["-profile\(spec)", "main"]
                    }
                    args += ["-pix_fmt\(spec)", "bgra", "-alpha_quality\(spec)", "0.8"]
                } else {
                    switch validProf {
                    case "main10":
                        args += ["-profile\(spec)", "main10", "-pix_fmt\(spec)", "p010le"]
                    case "main42210":
                        args += ["-profile\(spec)", "main42210", "-pix_fmt\(spec)", "p210le"]
                    case "main":
                        args += ["-profile\(spec)", "main", "-pix_fmt\(spec)", "yuv420p"]
                    default:
                        let sourceIs10Bit = pfLower.contains("10")
                        args += ["-pix_fmt\(spec)", sourceIs10Bit ? "p010le" : "yuv420p"]
                    }
                }
                
                args += ["-bf\(spec)", cfg.allowFrameReordering ? "2" : "0", "-allow_sw\(spec)", "1"]
                if binaryCapabilities.hevcVTSupportsRealtime {
                    args += ["-realtime\(spec)", "0"]
                }
                if cfg.spatialAQ && binaryCapabilities.hevcVTSupportsSpatialAQ {
                    args += ["-spatial_aq\(spec)", "1"]
                }
                
                if rcMode == .averageBitrate {
                    let br = normalizedBitrate(cfg.bitrate) ?? resolvedMultiPassBitrate(for: track)
                    args += ["-b\(spec)", br]
                    if let maxBr = cfg.maxBitrate.flatMap({ normalizedBitrate($0) }) {
                        args += ["-maxrate\(spec)", maxBr]
                        if let buf = doubleBitrateBufsize(from: maxBr) {
                            args += ["-bufsize\(spec)", buf]
                        }
                    }
                } else {
                    args += ["-q\(spec)", "\(cfg.qualityScale)"]
                }
                if let kf = cfg.keyFrameInterval, kf > 0 {
                    args += ["-g\(spec)", "\(kf)"]
                }
                
                if !usesVLD {
                    if needsDeinterlace {
                        filterParts.append("yadif=0:-1:1")
                    }
                    if let rotCPU = cfg.rotation.cpuFilterExpression {
                        filterParts.append(rotCPU)
                    }
                    if let targetW = cfg.resizeOption.targetWidth {
                        filterParts.append("scale=\(targetW):-2:flags=lanczos")
                    }
                    setparamsParts.append("field_mode=prog")
                    args += ["-field_order\(spec)", "progressive"]
                }
            }
            
            if isMP4Like && pass != 1 {
                args += ["-tag\(spec)", "hvc1"]
            }
            
        case .transcodeProRes:
            let validProResProfiles = ["0", "1", "2", "3", "4", "5"]
            let profile = cfg.profile.flatMap { validProResProfiles.contains($0) ? $0 : nil } ?? "2"
            let canPreserveAlpha = (profile == "4" || profile == "5") && cfg.preserveAlpha && hasAlpha
            if useHardwareAcceleration {
                args += ["-c\(spec)", "prores_videotoolbox", "-profile\(spec)", profile]
                if !usesVLD {
                    let pixFmt = (profile == "4" || profile == "5")
                        ? (canPreserveAlpha ? "ayuv64le" : "p410le")
                        : "p210le"
                    args += ["-pix_fmt\(spec)", pixFmt]
                }
                args += ["-allow_sw\(spec)", "1"]
                if binaryCapabilities.proResVTSupportsVendor {
                    args += ["-vendor\(spec)", "apl0"]
                }
            } else {
                let pixFmt = (profile == "4" || profile == "5")
                    ? (canPreserveAlpha ? "yuva444p10le" : "yuv444p10le")
                    : "yuv422p10le"
                args += ["-c\(spec)", "prores_ks", "-profile\(spec)", profile, "-pix_fmt\(spec)", pixFmt]
                if binaryCapabilities.proResKsSupportsVendor {
                    args += ["-vendor\(spec)", "apl0"]
                }
            }
            
            if !usesVLD {
                if needsDeinterlace {
                    filterParts.append("yadif=0:-1:1")
                }
                if let rotCPU = cfg.rotation.cpuFilterExpression {
                    filterParts.append(rotCPU)
                }
                if let targetW = cfg.resizeOption.targetWidth {
                    filterParts.append("scale=\(targetW):-2:flags=lanczos")
                }
                switch cfg.fieldOrder {
                case .topFirst:
                    args += ["-flags\(spec)", "+ilme+ildct", "-field_order\(spec)", "tt"]
                    setparamsParts.append("field_mode=tff")
                case .bottomFirst:
                    args += ["-flags\(spec)", "+ilme+ildct", "-field_order\(spec)", "bb"]
                    setparamsParts.append("field_mode=bff")
                case .progressive:
                    setparamsParts.append("field_mode=prog")
                    args += ["-field_order\(spec)", "progressive"]
                case .auto, .none:
                    break
                }
            }
            
        case .transcodeAV1:
            args += ["-c\(spec)", "libsvtav1"]
            let svtPreset = max(-2, min(13, cfg.svtPreset ?? 6))
            args += ["-preset\(spec)", "\(svtPreset)"]
            
            let profLower = cfg.profile?.lowercased()
            let pixFmt: String
            if profLower == "10bit" {
                pixFmt = "yuv420p10le"
            } else if profLower == "8bit" {
                pixFmt = "yuv420p"
            } else {
                let sourceIs10Bit = pfLower.contains("10")
                pixFmt = sourceIs10Bit ? "yuv420p10le" : "yuv420p"
            }
            args += ["-pix_fmt\(spec)", pixFmt]
            
            var svtParams: [String] = []
            if rcMode == .averageBitrate || rcMode == .twoPassVBR {
                let br = normalizedBitrate(cfg.bitrate) ?? resolvedMultiPassBitrate(for: track)
                args += ["-b\(spec)", br]
                svtParams.append("rc=1")
            } else {
                args += ["-crf\(spec)", "\(mappedSVTAV1CRF(for: cfg.qualityScale))"]
                if let maxBr = cfg.maxBitrate.flatMap({ normalizedBitrate($0) }) {
                    svtParams.append("mbr=\(maxBr)")
                }
            }
            if !svtParams.isEmpty {
                args += ["-svtav1-params\(spec)", svtParams.joined(separator: ":")]
            }
            if let kf = cfg.keyFrameInterval, kf > 0 {
                args += ["-g\(spec)", "\(kf)"]
            }
            if needsDeinterlace {
                filterParts.append("yadif=0:-1:1")
            }
            if let rotCPU = cfg.rotation.cpuFilterExpression {
                filterParts.append(rotCPU)
            }
            if let targetW = cfg.resizeOption.targetWidth {
                filterParts.append("scale=\(targetW):-2:flags=lanczos")
            }
            setparamsParts.append("field_mode=prog")
            args += ["-field_order\(spec)", "progressive"]
            
        case .transcodeUncompressed8, .transcodeUncompressed10:
            if track.action == .transcodeUncompressed8 {
                args += ["-c\(spec)", "rawvideo", "-pix_fmt\(spec)", "uyvy422"]
                if isMP4Like {
                    args += ["-tag\(spec)", "2vuy"]
                }
            } else {
                args += ["-c\(spec)", "v210", "-pix_fmt\(spec)", "yuv422p10le"]
            }
            if needsDeinterlace {
                filterParts.append("yadif=0:-1:1")
            }
            if let rotCPU = cfg.rotation.cpuFilterExpression {
                filterParts.append(rotCPU)
            }
            if let targetW = cfg.resizeOption.targetWidth {
                filterParts.append("scale=\(targetW):-2:flags=lanczos")
            }
            switch cfg.fieldOrder {
            case .topFirst:
                args += ["-flags\(spec)", "+ilme+ildct", "-field_order\(spec)", "tt"]
                setparamsParts.append("field_mode=tff")
            case .bottomFirst:
                args += ["-flags\(spec)", "+ilme+ildct", "-field_order\(spec)", "bb"]
                setparamsParts.append("field_mode=bff")
            case .progressive:
                setparamsParts.append("field_mode=prog")
                args += ["-field_order\(spec)", "progressive"]
            case .auto, .none:
                break
            }
            
        default:
            return ["-c\(spec)", "copy"]
        }
        
        // Shared Video Transcode Properties (Frame Rate & Color Space + Unified Filter Chain)
        if let fps = cfg.frameRate?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fps.isEmpty,
           fps.lowercased() != "auto" {
            args += ["-r\(spec)", fps]
        }
        
        if usesVLD {
            var vtFilters: [String] = []
            if needsDeinterlace {
                vtFilters.append("yadif_videotoolbox=mode=send_frame:parity=auto:deint=interlaced")
            }
            if let dir = cfg.rotation.transposeVTDir {
                vtFilters.append("transpose_vt=dir=\(dir)")
            }
            var scaleVTOpts: [String] = []
            if let targetW = cfg.resizeOption.targetWidth {
                scaleVTOpts.append("w=\(targetW)")
                scaleVTOpts.append("h=-2")
            }
            if let cs = cfg.colorSpace, cs != .auto {
                if let p = cs.ffPrimaries { scaleVTOpts.append("color_primaries=\(p)") }
                if let t = cs.ffTransfer { scaleVTOpts.append("color_transfer=\(t)") }
                if let m = cs.ffMatrix { scaleVTOpts.append("color_matrix=\(m)") }
            }
            if !scaleVTOpts.isEmpty {
                vtFilters.append("scale_vt=" + scaleVTOpts.joined(separator: ":"))
            }
            if !vtFilters.isEmpty {
                args += ["-filter\(spec)", vtFilters.joined(separator: ",")]
            }
        } else {
            let colorSpec = resolvedOutputColorSpec(for: track, config: cfg)
            let explicitColorRequested = (cfg.colorSpace != nil && cfg.colorSpace != .auto)
            if let p = colorSpec.primaries, !p.isEmpty {
                if explicitColorRequested { setparamsParts.append("color_primaries=\(p)") }
                args += ["-color_primaries\(spec)", p]
            }
            if let t = colorSpec.transfer, !t.isEmpty {
                if explicitColorRequested { setparamsParts.append("color_trc=\(t)") }
                args += ["-color_trc\(spec)", t]
            }
            if let m = colorSpec.matrix, !m.isEmpty {
                if explicitColorRequested { setparamsParts.append("colorspace=\(m)") }
                args += ["-colorspace\(spec)", m]
            }
            
            if !setparamsParts.isEmpty {
                filterParts.append("setparams=" + setparamsParts.joined(separator: ":"))
            }
            if !filterParts.isEmpty {
                args += ["-filter\(spec)", filterParts.joined(separator: ",")]
            }
        }
        
        return args
    }
    
    private static func audioEncoderArguments(
        for track: MediaTrack,
        streamSpecifier spec: String,
        binaryCapabilities: FFmpegBinaryCapabilities = .assumedModernDefaults,
        loudnessMeasurement: LoudnormMeasurement? = nil
    ) -> [String] {
        var args: [String] = []
        switch track.action {
        case .copy:
            return ["-c\(spec)", "copy"]
        case .transcodeAAC_Stereo, .transcodeAAC_51:
            let fallbackBr = (track.action == .transcodeAAC_51) ? "384k" : "192k"
            let explicitBr = track.audioConfig.bitrate.trimmingCharacters(in: .whitespacesAndNewlines)
            let br = explicitBr.isEmpty ? fallbackBr : explicitBr
            if binaryCapabilities.supportsAudioToolboxAAC {
                args += ["-c\(spec)", "aac_at", "-aac_at_mode\(spec)", track.audioConfig.aacMode.rawValue]
                if track.audioConfig.aacMode == .vbrQuality {
                    args += ["-q\(spec)", "\(track.audioConfig.aacQuality)"]
                } else {
                    args += ["-b\(spec)", br]
                }
            } else {
                args += ["-c\(spec)", "aac", "-b\(spec)", br]
            }
        case .transcodeMP3:
            args += ["-c\(spec)", "libmp3lame"]
            if track.audioConfig.isVBR {
                let q = track.audioConfig.bitrate == "V0" ? "0" : (track.audioConfig.bitrate == "V2" ? "2" : "4")
                args += ["-q\(spec)", q]
            } else {
                args += ["-b\(spec)", track.audioConfig.bitrate.isEmpty ? "320k" : track.audioConfig.bitrate]
            }
        case .transcodeALAC:
            args += ["-c\(spec)", "alac"]
            if track.audioConfig.bitDepth == "24" {
                args += ["-sample_fmt\(spec)", "s32p"]
            } else if track.audioConfig.bitDepth == "16" {
                args += ["-sample_fmt\(spec)", "s16p"]
            }
        case .transcodeAC3_51:
            let br = track.audioConfig.bitrate.isEmpty ? "640k" : track.audioConfig.bitrate
            args += ["-c\(spec)", "ac3", "-b\(spec)", br]
        case .transcodeEAC3_51:
            let br = track.audioConfig.bitrate.isEmpty ? "640k" : track.audioConfig.bitrate
            args += ["-c\(spec)", "eac3", "-b\(spec)", br]
        case .transcodeOpus:
            let br = track.audioConfig.bitrate.isEmpty ? "510k" : track.audioConfig.bitrate
            args += ["-c\(spec)", "libopus", "-b\(spec)", br]
        case .transcodeFLAC:
            args += ["-c\(spec)", "flac"]
            if track.audioConfig.bitDepth == "24" {
                args += ["-sample_fmt\(spec)", "s32"]
            } else if track.audioConfig.bitDepth == "16" {
                args += ["-sample_fmt\(spec)", "s16"]
            }
        case .transcodeWAV:
            let pcmCodec: String
            switch track.audioConfig.bitDepth {
            case "32float": pcmCodec = "pcm_f32le"
            case "32": pcmCodec = "pcm_s32le"
            case "24": pcmCodec = "pcm_s24le"
            case "8": pcmCodec = "pcm_u8"
            default: pcmCodec = "pcm_s16le"
            }
            args += ["-c\(spec)", pcmCodec]
        case .transcodeAIFF:
            let pcmCodec: String
            switch track.audioConfig.bitDepth {
            case "32float": pcmCodec = "pcm_f32be"
            case "32": pcmCodec = "pcm_s32be"
            case "24": pcmCodec = "pcm_s24be"
            case "8": pcmCodec = "pcm_s8"
            default: pcmCodec = "pcm_s16be"
            }
            args += ["-c\(spec)", pcmCodec]
        default:
            return ["-c\(spec)", "copy"]
        }
        
        let targetLoudness = track.audioConfig.loudnessTarget
        if targetLoudness != .off,
           binaryCapabilities.supportsLoudnorm,
           let targetLUFS = targetLoudness.integratedLUFS {
            let loudFilter: String
            if let measured = loudnessMeasurement {
                loudFilter = String(
                    format: "loudnorm=I=%.1f:TP=%.1f:LRA=%.1f:measured_I=%.2f:measured_TP=%.2f:measured_LRA=%.2f:measured_thresh=%.2f:offset=%.2f:linear=true:print_format=summary",
                    targetLUFS,
                    targetLoudness.truePeakDBTP,
                    targetLoudness.lraTarget,
                    measured.inputI,
                    measured.inputTP,
                    measured.inputLRA,
                    measured.inputThresh,
                    measured.targetOffset
                )
            } else {
                loudFilter = String(
                    format: "loudnorm=I=%.1f:TP=%.1f:LRA=%.1f",
                    targetLUFS,
                    targetLoudness.truePeakDBTP,
                    targetLoudness.lraTarget
                )
            }
            args += ["-af\(spec)", loudFilter]
        }
        
        // Channel downmixing / remixing if specified
        if let ch = track.audioConfig.channels {
            args += ["-ac\(spec)", "\(ch)"]
        }
        // Sample rate (forced whenever explicit SR OR loudnorm active so 192 kHz loudnorm upsampling never breaks encoders)
        if let sr = track.audioConfig.sampleRate {
            args += ["-ar\(spec)", sr]
        } else if targetLoudness != .off && binaryCapabilities.supportsLoudnorm {
            let fallbackSR = track.sampleRate ?? "48000"
            args += ["-ar\(spec)", fallbackSR]
        }
        
        return args
    }
    
    /// Builds Pass-1 EBU R128 loudness analysis arguments for a single audio track.
    public static func buildLoudnormAnalysisArguments(
        for file: MediaFile,
        track: MediaTrack
    ) -> [String]? {
        let target = track.audioConfig.loudnessTarget
        guard track.mediaType == .audio,
              track.action != .copy,
              target != .off,
              let targetLUFS = target.integratedLUFS else {
            return nil
        }
        let inputURL = (track.isExternal ? track.externalURL : nil) ?? file.url
        let filter = String(
            format: "loudnorm=I=%.1f:TP=%.1f:LRA=%.1f:print_format=json",
            targetLUFS,
            target.truePeakDBTP,
            target.lraTarget
        )
        return [
            "-hide_banner", "-nostats",
            "-i", inputURL.path,
            "-map", "0:\(track.streamIndex)",
            "-af", filter,
            "-vn", "-sn", "-dn",
            "-f", "null", "-"
        ]
    }
    
    /// Parses JSON summary emitted by FFmpeg's `loudnorm=print_format=json`.
    public static func parseLoudnormJSON(from stderr: String) -> LoudnormMeasurement? {
        guard let endIdx = stderr.lastIndex(of: "}") else { return nil }
        guard let startIdx = stderr[..<endIdx].lastIndex(of: "{") else { return nil }
        let jsonString = String(stderr[startIdx...endIdx])
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        func dbl(_ key: String) -> Double? {
            if let d = dict[key] as? Double { return d }
            if let s = dict[key] as? String { return Double(s) }
            return nil
        }
        guard let i = dbl("input_i"),
              let tp = dbl("input_tp"),
              let lra = dbl("input_lra"),
              let thresh = dbl("input_thresh"),
              let offset = dbl("target_offset") else {
            return nil
        }
        return LoudnormMeasurement(
            inputI: i,
            inputTP: tp,
            inputLRA: lra,
            inputThresh: thresh,
            targetOffset: offset
        )
    }
    
    // MARK: - Segmented Export Argument Builders
    
    public static func segmentedChunkContainerExtension(
        for videoTrack: MediaTrack,
        targetContainer: ContainerFormat
    ) -> String {
        if targetContainer == .mkv {
            return "mkv"
        }
        if targetContainer == .webm {
            return "webm"
        }
        if targetContainer == .mov
            || videoTrack.action == .transcodeProRes
            || videoTrack.action == .transcodeUncompressed8
            || videoTrack.action == .transcodeUncompressed10 {
            return "mov"
        }
        return "mp4"
    }
    
    public static func requiresSidecarAudioSubtitlePass(
        for selectedTracks: [MediaTrack],
        targetContainer: ContainerFormat
    ) -> Bool {
        let nonVideoTracks = selectedTracks.filter { $0.mediaType != .video }
        guard !nonVideoTracks.isEmpty else { return false }
        let isMP4Like = (targetContainer == .mp4 || targetContainer == .m4v || targetContainer == .mov)
        return nonVideoTracks.contains { track in
            if track.isExternal { return true }
            if track.action != .copy { return true }
            if isMP4Like && track.mediaType == .subtitle { return true }
            return false
        }
    }
    
    public static func buildSegmentedVideoChunkArguments(
        for file: MediaFile,
        videoTrack: MediaTrack,
        boundary: VideoSegmentBoundary,
        options: RemuxOptions,
        chunkOutputURL: URL,
        binaryCapabilities: FFmpegBinaryCapabilities = .assumedModernDefaults
    ) -> [String] {
        var args: [String] = ["-y", "-hide_banner"]
        
        if let seekTime = boundary.seekTime {
            args += ["-ss", String(format: "%.6f", seekTime)]
        }
        if options.useHardwareAcceleration {
            let usesVLD = ExecutionPlanner.canUseZeroCopyVLD(
                for: videoTrack,
                useHardwareAcceleration: options.useHardwareAcceleration,
                pass: nil,
                binaryCapabilities: binaryCapabilities
            )
            if usesVLD {
                args += ["-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld"]
            } else {
                args += ["-hwaccel", "videotoolbox"]
            }
        }
        
        args += ["-i", file.url.path]
        
        if boundary.exactEndPTS != nil {
            args += ["-t", String(format: "%.6f", boundary.expectedDuration)]
        }
        
        args += ["-map", "0:\(videoTrack.streamIndex)", "-an", "-sn", "-dn"]
        
        let isMP4Like = (options.targetContainer == .mp4 || options.targetContainer == .m4v || options.targetContainer == .mov)
        args += videoEncoderArguments(
            for: videoTrack,
            streamSpecifier: ":v:0",
            isMP4Like: isMP4Like,
            pass: nil,
            passLogBaseURL: nil,
            useHardwareAcceleration: options.useHardwareAcceleration,
            binaryCapabilities: binaryCapabilities
        )
        
        args.append(chunkOutputURL.path)
        return args
    }
    
    public static func buildSegmentedAudioSubtitleArguments(
        for file: MediaFile,
        nonVideoTracks: [MediaTrack],
        options: RemuxOptions,
        sidecarOutputURL: URL,
        binaryCapabilities: FFmpegBinaryCapabilities = .assumedModernDefaults,
        loudnessMeasurements: [UUID: LoudnormMeasurement] = [:]
    ) -> [String] {
        var args: [String] = ["-y", "-hide_banner", "-i", file.url.path]
        
        var externalInputMap: [URL: Int] = [:]
        var nextInputIndex = 1
        
        for track in nonVideoTracks where track.isExternal {
            if let extURL = track.externalURL, externalInputMap[extURL] == nil {
                externalInputMap[extURL] = nextInputIndex
                nextInputIndex += 1
                args += ["-i", extURL.path]
            }
        }
        
        for track in nonVideoTracks {
            if track.isExternal, let extURL = track.externalURL, let inputIdx = externalInputMap[extURL] {
                args += ["-map", "\(inputIdx):\(track.streamIndex)"]
            } else {
                args += ["-map", "0:\(track.streamIndex)"]
            }
        }
        
        let isMP4Like = (options.targetContainer == .mp4 || options.targetContainer == .m4v || options.targetContainer == .mov)
        var audioOutIdx = 0
        var subtitleOutIdx = 0
        
        for track in nonVideoTracks {
            switch track.mediaType {
            case .audio:
                args += audioEncoderArguments(
                    for: track,
                    streamSpecifier: ":a:\(audioOutIdx)",
                    binaryCapabilities: binaryCapabilities,
                    loudnessMeasurement: loudnessMeasurements[track.id]
                )
                audioOutIdx += 1
            case .subtitle:
                if isMP4Like {
                    args += ["-c:s:\(subtitleOutIdx)", "mov_text"]
                } else {
                    switch track.action {
                    case .transcodeSRT:
                        args += ["-c:s:\(subtitleOutIdx)", "subrip"]
                    case .transcodeMovText:
                        args += ["-c:s:\(subtitleOutIdx)", "mov_text"]
                    default:
                        args += ["-c:s:\(subtitleOutIdx)", "copy"]
                    }
                }
                subtitleOutIdx += 1
            default:
                break
            }
        }
        
        args += ["-vn", "-dn"]
        args.append(sidecarOutputURL.path)
        return args
    }
    
    public static func buildSegmentedStitchArguments(
        for file: MediaFile,
        concatListURL: URL,
        sidecarAudioSubURL: URL?,
        options: RemuxOptions,
        binaryCapabilities: FFmpegBinaryCapabilities = .assumedModernDefaults,
        usesAnnexBChunks: Bool = false
    ) throws -> [String] {
        let selectedTracks = file.tracks.filter { $0.isSelected }
        guard !selectedTracks.isEmpty else {
            throw RemuxError.noTracksSelected
        }
        
        var args: [String] = [
            "-y", "-hide_banner",
            "-f", "concat", "-safe", "0", "-i", concatListURL.path
        ]
        
        let nonVideoTracks = selectedTracks.filter { $0.mediaType != .video }
        let needsOriginalMetadata = !options.stripAllMetadata || !options.stripChapters
        
        var nonVideoInputIdx: Int? = nil
        var metadataInputIdx: Int? = nil
        var nextInputIdx = 1
        
        if let sidecarURL = sidecarAudioSubURL {
            args += ["-i", sidecarURL.path]
            nonVideoInputIdx = nextInputIdx
            nextInputIdx += 1
            if needsOriginalMetadata {
                args += ["-i", file.url.path]
                metadataInputIdx = nextInputIdx
                nextInputIdx += 1
            }
        } else if !nonVideoTracks.isEmpty || needsOriginalMetadata {
            args += ["-i", file.url.path]
            nonVideoInputIdx = nextInputIdx
            metadataInputIdx = nextInputIdx
            nextInputIdx += 1
        }
        
        var sidecarOutStreamIdx = 0
        for track in selectedTracks {
            if track.mediaType == .video {
                args += ["-map", "0:v:0"]
            } else if let inputIdx = nonVideoInputIdx {
                if sidecarAudioSubURL != nil {
                    args += ["-map", "\(inputIdx):\(sidecarOutStreamIdx)"]
                    sidecarOutStreamIdx += 1
                } else {
                    args += ["-map", "\(inputIdx):\(track.streamIndex)"]
                }
            }
        }
        
        args += ["-c", "copy", "-avoid_negative_ts", "make_zero"]
        
        let isMP4Like = (options.targetContainer == .mp4 || options.targetContainer == .m4v || options.targetContainer == .mov)
        if let videoTrack = selectedTracks.first(where: { $0.mediaType == .video }) {
            let isH264OrHEVC = videoTrack.action == .transcodeH264_VT
                || videoTrack.action == .transcodeHEVC_VT
                || videoTrack.isHEVCCodec
                || videoTrack.codecName.lowercased().contains("h264")
                || videoTrack.codecName.lowercased().contains("avc")
            // `dump_extra` is strictly for Annex-B / MPEG-TS chunks; applying it to length-prefixed MP4/MKV chunks corrupts NAL length prefixes.
            if usesAnnexBChunks && binaryCapabilities.supportsDumpExtraBSF && isH264OrHEVC {
                args += ["-bsf:v:0", "dump_extra"]
            }
            if isMP4Like && (videoTrack.action == .transcodeHEVC_VT || (videoTrack.action == .copy && videoTrack.isHEVCCodec && videoTrack.hasHEV1Tag)) {
                args += ["-tag:v:0", "hvc1"]
            }
        }
        
        for (totalOutIdx, track) in selectedTracks.enumerated() {
            if !track.language.isEmpty && track.language != "und" {
                args += ["-metadata:s:\(totalOutIdx)", "language=\(track.language)"]
            }
            if !track.title.isEmpty {
                args += ["-metadata:s:\(totalOutIdx)", "title=\(track.title)"]
            }
            if track.isDefault {
                args += ["-disposition:s:\(totalOutIdx)", "default"]
            } else if track.isForced {
                args += ["-disposition:s:\(totalOutIdx)", "forced"]
            }
        }
        
        if options.stripAllMetadata {
            args += ["-map_metadata", "-1"]
        } else if let metaIdx = metadataInputIdx {
            args += ["-map_metadata", "\(metaIdx)"]
        }
        
        if options.stripChapters {
            args += ["-map_chapters", "-1"]
        } else if let metaIdx = metadataInputIdx {
            args += ["-map_chapters", "\(metaIdx)"]
        }
        
        if isMP4Like && options.fastStart {
            args += ["-movflags", "+faststart"]
        }
        
        args.append(options.outputURL.path)
        return args
    }
    
    // MARK: - Process Runner Helpers
    
    private func runFFmpegProcess(
        ffmpegPath: String,
        arguments: [String],
        duration: Double,
        progressScale: Double,
        progressOffset: Double,
        speedPrefix: String?,
        activeSegments: Int? = nil,
        phaseLabel: String? = nil,
        notice: String? = nil,
        executionTierLabel: String? = nil,
        continuation: AsyncStream<RemuxProgress>.Continuation
    ) async -> Int32 {
        let processID = UUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments
        
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        
        let (terminationStream, terminationContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { terminatedProcess in
            terminatedProcess.terminationHandler = nil
            terminationContinuation.yield(terminatedProcess.terminationStatus)
            terminationContinuation.finish()
        }
        
        registerProcess(process, id: processID)
        
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            terminationContinuation.finish()
            unregisterProcess(id: processID)
            return -1
        }
        
        if self.isCancelled {
            if process.isRunning { process.terminate() }
            unregisterProcess(id: processID)
            return -1
        }
        
        let fileHandle = stderrPipe.fileHandleForReading
        var lineBuffer = Data()
        lineBuffer.reserveCapacity(256)
        
        do {
            for try await byteData in fileHandle.bytes {
                if self.isCancelled { break }
                
                if byteData == 0x0A || byteData == 0x0D {
                    if !lineBuffer.isEmpty {
                        if let line = String(data: lineBuffer, encoding: .utf8),
                           let update = MediaFormatters.parseFFmpegProgress(line: line, totalDuration: duration) {
                            let scaledProgress = min(1.0, max(0.0, progressOffset + (update.progress * progressScale)))
                            let speedLabel = speedPrefix.map { "\($0) • \(update.speed)" } ?? update.speed
                            continuation.yield(RemuxProgress(
                                progress: scaledProgress,
                                currentTime: update.currentTime,
                                totalTime: update.totalTime,
                                fps: update.fps,
                                speed: speedLabel,
                                bitrate: update.bitrate,
                                frame: update.frame,
                                remainingSeconds: update.remainingSeconds,
                                activeSegments: activeSegments,
                                phaseLabel: phaseLabel,
                                notice: notice,
                                executionTierLabel: executionTierLabel
                            ))
                        }
                        lineBuffer.removeAll(keepingCapacity: true)
                    }
                } else {
                    lineBuffer.append(byteData)
                }
            }
        } catch {
            // Stream read terminated
        }
        
        // Flush any trailing line buffered before EOF
        if !self.isCancelled && !lineBuffer.isEmpty {
            if let line = String(data: lineBuffer, encoding: .utf8),
               let update = MediaFormatters.parseFFmpegProgress(line: line, totalDuration: duration) {
                let scaledProgress = min(1.0, max(0.0, progressOffset + (update.progress * progressScale)))
                let speedLabel = speedPrefix.map { "\($0) • \(update.speed)" } ?? update.speed
                continuation.yield(RemuxProgress(
                    progress: scaledProgress,
                    currentTime: update.currentTime,
                    totalTime: update.totalTime,
                    fps: update.fps,
                    speed: speedLabel,
                    bitrate: update.bitrate,
                    frame: update.frame,
                    remainingSeconds: update.remainingSeconds,
                    activeSegments: activeSegments,
                    phaseLabel: phaseLabel,
                    notice: notice,
                    executionTierLabel: executionTierLabel
                ))
            }
        }
        
        var exitStatus: Int32?
        for await status in terminationStream {
            exitStatus = status
            break
        }
        process.terminationHandler = nil
        let finalStatus = exitStatus ?? (process.isRunning ? -1 : process.terminationStatus)
        unregisterProcess(id: processID)
        return finalStatus
    }
    
    private func measureLoudnorm(
        for file: MediaFile,
        track: MediaTrack,
        ffmpegPath: String
    ) async -> LoudnormMeasurement? {
        guard !self.isCancelled,
              let args = Self.buildLoudnormAnalysisArguments(for: file, track: track) else {
            return nil
        }
        
        let processID = UUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        
        let (terminationStream, terminationContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { terminatedProcess in
            terminatedProcess.terminationHandler = nil
            terminationContinuation.yield(terminatedProcess.terminationStatus)
            terminationContinuation.finish()
        }
        registerProcess(process, id: processID)
        
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            terminationContinuation.finish()
            unregisterProcess(id: processID)
            return nil
        }
        
        if self.isCancelled {
            if process.isRunning { process.terminate() }
            unregisterProcess(id: processID)
            return nil
        }
        
        var errData = Data()
        do {
            for try await byteData in stderrPipe.fileHandleForReading.bytes {
                if self.isCancelled { break }
                errData.append(byteData)
            }
        } catch {
            // Stream read terminated
        }
        
        var exitStatus: Int32?
        for await status in terminationStream {
            exitStatus = status
            break
        }
        process.terminationHandler = nil
        unregisterProcess(id: processID)
        
        guard !self.isCancelled,
              exitStatus == 0,
              let stderrText = String(data: errData, encoding: .utf8) else {
            return nil
        }
        return Self.parseLoudnormJSON(from: stderrText)
    }
    
    private func evaluatePerceptualQCIfNeeded(
        file: MediaFile,
        options: RemuxOptions,
        ffmpegPath: String,
        binaryCapabilities: FFmpegBinaryCapabilities,
        executionTierLabel: String?,
        continuation: AsyncStream<RemuxProgress>.Continuation
    ) async -> PerceptualQCResult? {
        guard !self.isCancelled,
              options.perceptualQCMetric != .none else {
            return nil
        }
        let hasTranscodedVideo = file.tracks.contains {
            $0.isSelected && $0.mediaType == .video && $0.action != .copy
        }
        guard hasTranscodedVideo else { return nil }
        if options.perceptualQCMetric == .xpsnr && !binaryCapabilities.supportsXPSNR {
            return nil
        }
        if options.perceptualQCMetric == .libvmaf && !binaryCapabilities.supportsLibVMAF {
            return nil
        }
        
        continuation.yield(RemuxProgress(
            progress: 0.97,
            currentTime: file.duration,
            totalTime: file.duration,
            speed: "QC...",
            activeSegments: 1,
            phaseLabel: "Running \(options.perceptualQCMetric.shortLabel) QC...",
            executionTierLabel: executionTierLabel
        ))
        
        return await PerceptualQCRunner.evaluate(
            distortedURL: options.outputURL,
            referenceURL: file.url,
            metric: options.perceptualQCMetric,
            ffmpegPath: ffmpegPath
        )
    }
    
    private func runWorkerFFmpeg(
        ffmpegPath: String,
        arguments: [String],
        chunkDuration: Double,
        onProgress: @Sendable (RemuxProgress) async -> Void
    ) async -> Int32 {
        let processID = UUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments
        
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        
        let (terminationStream, terminationContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { terminatedProcess in
            terminatedProcess.terminationHandler = nil
            terminationContinuation.yield(terminatedProcess.terminationStatus)
            terminationContinuation.finish()
        }
        
        registerProcess(process, id: processID)
        
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            terminationContinuation.finish()
            unregisterProcess(id: processID)
            return -1
        }
        
        if self.isCancelled {
            if process.isRunning { process.terminate() }
            unregisterProcess(id: processID)
            return -1
        }
        
        let fileHandle = stderrPipe.fileHandleForReading
        var lineBuffer = Data()
        lineBuffer.reserveCapacity(256)
        
        do {
            for try await byteData in fileHandle.bytes {
                if self.isCancelled { break }
                if byteData == 0x0A || byteData == 0x0D {
                    if !lineBuffer.isEmpty {
                        if let line = String(data: lineBuffer, encoding: .utf8),
                           let update = MediaFormatters.parseFFmpegProgress(line: line, totalDuration: chunkDuration) {
                            await onProgress(update)
                        }
                        lineBuffer.removeAll(keepingCapacity: true)
                    }
                } else {
                    lineBuffer.append(byteData)
                }
            }
        } catch {
            // Stream read terminated
        }
        
        if !self.isCancelled && !lineBuffer.isEmpty {
            if let line = String(data: lineBuffer, encoding: .utf8),
               let update = MediaFormatters.parseFFmpegProgress(line: line, totalDuration: chunkDuration) {
                await onProgress(update)
            }
        }
        
        var exitStatus: Int32?
        for await status in terminationStream {
            exitStatus = status
            break
        }
        process.terminationHandler = nil
        let finalStatus = exitStatus ?? (process.isRunning ? -1 : process.terminationStatus)
        unregisterProcess(id: processID)
        return finalStatus
    }
    
    /// Executes the remux job and yields progress updates asynchronously.
    public func run(
        file: MediaFile,
        options: RemuxOptions,
        ffmpegPathOverride: String? = nil,
        ffprobePathOverride: String? = nil,
        capabilitiesOverride: HardwareMediaCapabilities? = nil
    ) -> AsyncStream<RemuxProgress> {
        self.isCancelled = false
        
        return AsyncStream { continuation in
            _ = Task {
                guard let ffmpegPath = ffmpegPathOverride ?? FFmpegLocator.shared.ffmpegPath else {
                    continuation.finish()
                    return
                }
                
                // Ensure parent directory of output exists
                let parentDir = options.outputURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                
                let binCaps = await BinaryCapabilityProbe.shared.capabilities(for: ffmpegPath)
                let plan = ExecutionPlanner.plan(for: file, options: options, binaryCapabilities: binCaps)
                
                if plan.requiresDolbyVisionGuard {
                    continuation.yield(RemuxProgress(
                        progress: 0.0,
                        currentTime: 0,
                        totalTime: file.duration,
                        speed: "Blocked",
                        activeSegments: 1,
                        phaseLabel: "Dolby Vision Guard",
                        notice: plan.dolbyVisionWarningMessage ?? "Dolby Vision transcode blocked to protect RPU dynamic metadata.",
                        executionTierLabel: plan.badgeTitle
                    ))
                    continuation.finish()
                    return
                }
                
                let capabilities: HardwareMediaCapabilities
                if let override = capabilitiesOverride {
                    capabilities = override
                } else {
                    capabilities = await HardwareCapabilities.detectWithCoordinator(self.coordinator)
                }
                
                let selectedTracks = file.tracks.filter { $0.isSelected }
                
                // Pass 1 for any selected audio track with EBU R128 loudness normalization enabled
                var loudnessMeasurements: [UUID: LoudnormMeasurement] = [:]
                let tracksNeedingLoudnorm = selectedTracks.filter {
                    $0.mediaType == .audio && $0.action != .copy && $0.audioConfig.loudnessTarget != .off
                }
                if !tracksNeedingLoudnorm.isEmpty && binCaps.supportsLoudnorm && !self.isCancelled {
                    continuation.yield(RemuxProgress(
                        progress: 0.0,
                        currentTime: 0,
                        totalTime: file.duration,
                        speed: "Analyzing...",
                        activeSegments: 1,
                        phaseLabel: "Measuring EBU R128 Loudness...",
                        executionTierLabel: plan.badgeTitle
                    ))
                    for audioTrack in tracksNeedingLoudnorm {
                        if self.isCancelled { break }
                        if let measurement = await self.measureLoudnorm(for: file, track: audioTrack, ffmpegPath: ffmpegPath) {
                            loudnessMeasurements[audioTrack.id] = measurement
                        }
                    }
                    if self.isCancelled {
                        continuation.finish()
                        return
                    }
                }
                
                // Route eligible VideoToolbox 2-Pass VBR jobs through Native Swift AVAssetReader/VTCompressionSession
                if plan.usesNativeVideoToolbox,
                   let videoTrack = selectedTracks.first(where: { $0.mediaType == .video }) {
                    let targetStr = Self.resolvedMultiPassBitrate(for: videoTrack)
                    let targetBps = Self.parseBitrateBps(targetStr) ?? 8_000_000
                    let maxBps = videoTrack.videoConfig.maxBitrate.flatMap { Self.parseBitrateBps($0) }
                    
                    await self.coordinator.acquire(family: .ave, count: 1)
                    let nativeEngine = NativeVideoToolboxEngine()
                    self.setActiveNativeEngine(nativeEngine)
                    let nativeResult = await nativeEngine.runTwoPassEncode(
                        file: file,
                        videoTrack: videoTrack,
                        options: options,
                        targetBitrateBps: targetBps,
                        maxBitrateBps: maxBps,
                        notice: plan.reasonSummary
                    ) { update in
                        continuation.yield(update)
                    }
                    self.setActiveNativeEngine(nil)
                    await self.coordinator.release(family: .ave, count: 1)
                    
                    if nativeResult.succeeded && !self.isCancelled {
                        let qcResult = await self.evaluatePerceptualQCIfNeeded(
                            file: file,
                            options: options,
                            ffmpegPath: ffmpegPath,
                            binaryCapabilities: binCaps,
                            executionTierLabel: plan.badgeTitle,
                            continuation: continuation
                        )
                        if qcResult != nil || nativeResult.pixelBufferPoolShared {
                            continuation.yield(RemuxProgress(
                                progress: 1.0,
                                currentTime: file.duration,
                                totalTime: file.duration,
                                speed: "Done",
                                activeSegments: 1,
                                phaseLabel: nil,
                                notice: plan.reasonSummary,
                                executionTierLabel: plan.badgeTitle,
                                qcSummary: qcResult?.summary,
                                pixelBufferPoolShared: nativeResult.pixelBufferPoolShared
                            ))
                        }
                        continuation.finish()
                        return
                    }
                    
                    if self.isCancelled {
                        try? FileManager.default.removeItem(at: options.outputURL)
                        continuation.finish()
                        return
                    }
                }
                
                let decision = HardwareCapabilities.resolveSegmentation(
                    for: file,
                    options: options,
                    capabilities: capabilities
                )
                
                let needsTwoPass = selectedTracks.contains {
                    $0.mediaType == .video &&
                    ($0.videoConfig.multiPass || $0.videoConfig.effectiveRateControlMode == .twoPassVBR) &&
                    ($0.action == .transcodeH264_VT || $0.action == .transcodeHEVC_VT)
                }
                
                if decision.isSegmented,
                   !needsTwoPass,
                   let videoTrack = selectedTracks.first(where: { $0.mediaType == .video }),
                   let ffprobePath = ffprobePathOverride ?? FFmpegLocator.shared.ffprobePath {
                    
                    let minimumChunkDur = min(2.5, max(1.0, file.duration / Double(decision.segmentCount * 2)))
                    let boundaries = await KeyframeProber.probeBoundaries(
                        fileURL: file.url,
                        videoStreamIndex: videoTrack.streamIndex,
                        duration: file.duration,
                        startTime: file.startTime,
                        segmentCount: decision.segmentCount,
                        ffprobePath: ffprobePath,
                        minimumChunkDuration: minimumChunkDur
                    )
                    
                    if boundaries.count >= 2 && !self.isCancelled {
                        await self.runSegmented(
                            file: file,
                            videoTrack: videoTrack,
                            boundaries: boundaries,
                            options: options,
                            decision: decision,
                            ffmpegPath: ffmpegPath,
                            binaryCapabilities: binCaps,
                            loudnessMeasurements: loudnessMeasurements,
                            executionTierLabel: plan.badgeTitle,
                            continuation: continuation
                        )
                        continuation.finish()
                        return
                    } else if !self.isCancelled {
                        let sparseNotice = decision.notice ?? "Sparse keyframes prevented splitting — running single-stream mode."
                        await self.runSingleStream(
                            file: file,
                            options: options,
                            needsTwoPass: false,
                            ffmpegPath: ffmpegPath,
                            family: decision.engineFamily,
                            notice: sparseNotice,
                            binaryCapabilities: binCaps,
                            loudnessMeasurements: loudnessMeasurements,
                            executionTierLabel: plan.badgeTitle,
                            continuation: continuation
                        )
                        continuation.finish()
                        return
                    }
                }
                
                await self.runSingleStream(
                    file: file,
                    options: options,
                    needsTwoPass: needsTwoPass,
                    ffmpegPath: ffmpegPath,
                    family: decision.engineFamily,
                    notice: decision.notice ?? plan.reasonSummary,
                    binaryCapabilities: binCaps,
                    loudnessMeasurements: loudnessMeasurements,
                    executionTierLabel: plan.badgeTitle,
                    continuation: continuation
                )
                
                continuation.finish()
            }
        }
    }
    
    private func runSingleStream(
        file: MediaFile,
        options: RemuxOptions,
        needsTwoPass: Bool,
        ffmpegPath: String,
        family: MediaEngineFamily?,
        notice: String?,
        binaryCapabilities: FFmpegBinaryCapabilities,
        loudnessMeasurements: [UUID: LoudnormMeasurement],
        executionTierLabel: String?,
        continuation: AsyncStream<RemuxProgress>.Continuation
    ) async {
        let duration = file.duration
        if let fam = family {
            await self.coordinator.acquire(family: fam, count: 1)
        }
        
        if let notice {
            continuation.yield(RemuxProgress(
                progress: 0.0,
                currentTime: 0,
                totalTime: duration,
                speed: "Starting...",
                activeSegments: 1,
                phaseLabel: executionTierLabel ?? "Single Stream",
                notice: notice,
                executionTierLabel: executionTierLabel
            ))
        }
        
        var encodeSucceeded = false
        if needsTwoPass {
            let passLogDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("strata_2pass_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: passLogDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: passLogDir)
            }
            
            if let pass1Args = try? Self.buildArguments(
                for: file,
                options: options,
                pass: 1,
                passLogBaseURL: passLogDir,
                binaryCapabilities: binaryCapabilities,
                loudnessMeasurements: loudnessMeasurements
            ),
               let pass2Args = try? Self.buildArguments(
                for: file,
                options: options,
                pass: 2,
                passLogBaseURL: passLogDir,
                binaryCapabilities: binaryCapabilities,
                loudnessMeasurements: loudnessMeasurements
               ) {
                
                let status1 = await self.runFFmpegProcess(
                    ffmpegPath: ffmpegPath,
                    arguments: pass1Args,
                    duration: duration,
                    progressScale: 0.5,
                    progressOffset: 0.0,
                    speedPrefix: "Pass 1/2",
                    activeSegments: 1,
                    phaseLabel: nil,
                    notice: notice,
                    executionTierLabel: executionTierLabel,
                    continuation: continuation
                )
                
                if !self.isCancelled && status1 == 0 {
                    let status2 = await self.runFFmpegProcess(
                        ffmpegPath: ffmpegPath,
                        arguments: pass2Args,
                        duration: duration,
                        progressScale: 0.5,
                        progressOffset: 0.5,
                        speedPrefix: "Pass 2/2",
                        activeSegments: 1,
                        phaseLabel: nil,
                        notice: notice,
                        executionTierLabel: executionTierLabel,
                        continuation: continuation
                    )
                    encodeSucceeded = (!self.isCancelled && status2 == 0)
                }
            }
        } else if let arguments = try? Self.buildArguments(
            for: file,
            options: options,
            binaryCapabilities: binaryCapabilities,
            loudnessMeasurements: loudnessMeasurements
        ) {
            let status = await self.runFFmpegProcess(
                ffmpegPath: ffmpegPath,
                arguments: arguments,
                duration: duration,
                progressScale: 1.0,
                progressOffset: 0.0,
                speedPrefix: nil,
                activeSegments: 1,
                phaseLabel: nil,
                notice: notice,
                executionTierLabel: executionTierLabel,
                continuation: continuation
            )
            encodeSucceeded = (!self.isCancelled && status == 0)
        }
        
        if let fam = family {
            await self.coordinator.release(family: fam, count: 1)
        }
        
        if encodeSucceeded {
            let qcResult = await self.evaluatePerceptualQCIfNeeded(
                file: file,
                options: options,
                ffmpegPath: ffmpegPath,
                binaryCapabilities: binaryCapabilities,
                executionTierLabel: executionTierLabel,
                continuation: continuation
            )
            continuation.yield(RemuxProgress(
                progress: 1.0,
                currentTime: duration,
                totalTime: duration,
                speed: "Done",
                activeSegments: 1,
                phaseLabel: nil,
                notice: notice,
                executionTierLabel: executionTierLabel,
                qcSummary: qcResult?.summary
            ))
        } else if self.isCancelled {
            try? FileManager.default.removeItem(at: options.outputURL)
        }
    }
    
    private func runSegmented(
        file: MediaFile,
        videoTrack: MediaTrack,
        boundaries: [VideoSegmentBoundary],
        options: RemuxOptions,
        decision: SegmentationDecision,
        ffmpegPath: String,
        binaryCapabilities: FFmpegBinaryCapabilities,
        loudnessMeasurements: [UUID: LoudnormMeasurement],
        executionTierLabel: String?,
        continuation: AsyncStream<RemuxProgress>.Continuation
    ) async {
        let segmentCount = boundaries.count
        let totalDuration = max(0.01, file.duration)
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("strata_seg_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workDir)
        }
        
        if let fam = decision.engineFamily {
            await self.coordinator.acquire(family: fam, count: segmentCount)
        }
        
        let phaseTag = "\(segmentCount)× Segmented"
        continuation.yield(RemuxProgress(
            progress: 0.0,
            currentTime: 0,
            totalTime: totalDuration,
            speed: "Preparing...",
            activeSegments: segmentCount,
            phaseLabel: phaseTag,
            notice: decision.notice,
            executionTierLabel: executionTierLabel
        ))
        
        let chunkExt = Self.segmentedChunkContainerExtension(for: videoTrack, targetContainer: options.targetContainer)
        let chunkURLs: [URL] = boundaries.map { b in
            workDir.appendingPathComponent("chunk_\(b.index).\(chunkExt)")
        }
        
        let selectedTracks = file.tracks.filter { $0.isSelected }
        let nonVideoTracks = selectedTracks.filter { $0.mediaType != .video }
        let needsSidecar = Self.requiresSidecarAudioSubtitlePass(for: selectedTracks, targetContainer: options.targetContainer)
        let sidecarExt = options.targetContainer == .m4v ? "mp4" : options.targetContainer.fileExtension
        let sidecarURL: URL? = needsSidecar ? workDir.appendingPathComponent("sidecar_audio_subs.\(sidecarExt)") : nil
        
        let aggregator = SegmentedProgressAggregator(
            boundaries: boundaries,
            totalDuration: totalDuration,
            segmentCount: segmentCount,
            phaseLabel: phaseTag,
            notice: decision.notice,
            executionTierLabel: executionTierLabel
        )
        
        var allWorkersSucceeded = true
        
        await withTaskGroup(of: Int32.self) { group in
            for boundary in boundaries {
                let cURL = chunkURLs[boundary.index]
                let chunkArgs = Self.buildSegmentedVideoChunkArguments(
                    for: file,
                    videoTrack: videoTrack,
                    boundary: boundary,
                    options: options,
                    chunkOutputURL: cURL,
                    binaryCapabilities: binaryCapabilities
                )
                let expectedDur = max(0.1, boundary.expectedDuration)
                let idx = boundary.index
                
                group.addTask { [weak self] in
                    guard let self else { return -1 }
                    let exitCode = await self.runWorkerFFmpeg(
                        ffmpegPath: ffmpegPath,
                        arguments: chunkArgs,
                        chunkDuration: expectedDur
                    ) { update in
                        if let merged = await aggregator.updateChunk(index: idx, progress: update) {
                            continuation.yield(merged)
                        }
                    }
                    if exitCode == 0 {
                        if let merged = await aggregator.markChunkCompleted(index: idx) {
                            continuation.yield(merged)
                        }
                    }
                    return exitCode
                }
            }
            
            if let sURL = sidecarURL {
                let sidecarArgs = Self.buildSegmentedAudioSubtitleArguments(
                    for: file,
                    nonVideoTracks: nonVideoTracks,
                    options: options,
                    sidecarOutputURL: sURL,
                    binaryCapabilities: binaryCapabilities,
                    loudnessMeasurements: loudnessMeasurements
                )
                group.addTask { [weak self] in
                    guard let self else { return -1 }
                    return await self.runWorkerFFmpeg(
                        ffmpegPath: ffmpegPath,
                        arguments: sidecarArgs,
                        chunkDuration: totalDuration,
                        onProgress: { _ in }
                    )
                }
            }
            
            for await exitCode in group {
                if exitCode != 0 {
                    allWorkersSucceeded = false
                    self.cancel()
                }
            }
        }
        
        if let fam = decision.engineFamily {
            await self.coordinator.release(family: fam, count: segmentCount)
        }
        
        if self.isCancelled || !allWorkersSucceeded {
            try? FileManager.default.removeItem(at: options.outputURL)
            return
        }
        
        // Stitch phase (0.92 -> 1.00)
        let concatListURL = workDir.appendingPathComponent("concat_list.txt")
        let concatManifest = chunkURLs
            .map { url in
                let escaped = url.path.replacingOccurrences(of: "'", with: "'\\''")
                return "file '\(escaped)'"
            }
            .joined(separator: "\n") + "\n"
        do {
            try concatManifest.write(to: concatListURL, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        
        guard let stitchArgs = try? Self.buildSegmentedStitchArguments(
            for: file,
            concatListURL: concatListURL,
            sidecarAudioSubURL: sidecarURL,
            options: options,
            binaryCapabilities: binaryCapabilities
        ) else {
            return
        }
        
        continuation.yield(RemuxProgress(
            progress: 0.93,
            currentTime: totalDuration * 0.93,
            totalTime: totalDuration,
            speed: "Stitching...",
            activeSegments: segmentCount,
            phaseLabel: "Stitching segments...",
            notice: decision.notice,
            executionTierLabel: executionTierLabel
        ))
        
        let stitchStatus = await self.runFFmpegProcess(
            ffmpegPath: ffmpegPath,
            arguments: stitchArgs,
            duration: totalDuration,
            progressScale: 0.07,
            progressOffset: 0.93,
            speedPrefix: nil,
            activeSegments: segmentCount,
            phaseLabel: "Stitching segments...",
            notice: decision.notice,
            executionTierLabel: executionTierLabel,
            continuation: continuation
        )
        
        if !self.isCancelled && stitchStatus == 0 {
            let qcResult = await self.evaluatePerceptualQCIfNeeded(
                file: file,
                options: options,
                ffmpegPath: ffmpegPath,
                binaryCapabilities: binaryCapabilities,
                executionTierLabel: executionTierLabel,
                continuation: continuation
            )
            continuation.yield(RemuxProgress(
                progress: 1.0,
                currentTime: totalDuration,
                totalTime: totalDuration,
                speed: "Done",
                activeSegments: segmentCount,
                phaseLabel: nil,
                notice: decision.notice,
                executionTierLabel: executionTierLabel,
                qcSummary: qcResult?.summary
            ))
        } else {
            try? FileManager.default.removeItem(at: options.outputURL)
        }
    }
    
    /// Extracts a single track into a dedicated standalone file.
    public func extractTrack(
        file: MediaFile,
        track: MediaTrack,
        outputURL: URL,
        useHardwareAcceleration: Bool = true,
        ffmpegPathOverride: String? = nil
    ) -> AsyncStream<RemuxProgress> {
        self.isCancelled = false
        
        return AsyncStream { continuation in
            _ = Task {
                guard let ffmpegPath = ffmpegPathOverride ?? FFmpegLocator.shared.ffmpegPath else {
                    continuation.finish()
                    return
                }
                
                let binCaps = await BinaryCapabilityProbe.shared.capabilities(for: ffmpegPath)
                let needsTwoPass = track.mediaType == .video &&
                    (track.videoConfig.multiPass || track.videoConfig.effectiveRateControlMode == .twoPassVBR) &&
                    (track.action == .transcodeH264_VT || track.action == .transcodeHEVC_VT)
                
                // Ensure parent directory exists
                try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                
                let duration = file.duration
                var loudnessMeasurement: LoudnormMeasurement? = nil
                if track.mediaType == .audio && track.action != .copy && track.audioConfig.loudnessTarget != .off && binCaps.supportsLoudnorm {
                    loudnessMeasurement = await self.measureLoudnorm(for: file, track: track, ffmpegPath: ffmpegPath)
                    if self.isCancelled {
                        continuation.finish()
                        return
                    }
                }
                
                if needsTwoPass {
                    let passLogDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("strata_2pass_extract_\(UUID().uuidString)")
                    try? FileManager.default.createDirectory(at: passLogDir, withIntermediateDirectories: true)
                    defer {
                        try? FileManager.default.removeItem(at: passLogDir)
                    }
                    
                    let pass1Args = Self.buildTrackExtractionArguments(
                        file: file,
                        track: track,
                        outputURL: outputURL,
                        pass: 1,
                        passLogBaseURL: passLogDir,
                        useHardwareAcceleration: useHardwareAcceleration,
                        binaryCapabilities: binCaps,
                        loudnessMeasurement: loudnessMeasurement
                    )
                    let status1 = await self.runFFmpegProcess(
                        ffmpegPath: ffmpegPath,
                        arguments: pass1Args,
                        duration: duration,
                        progressScale: 0.5,
                        progressOffset: 0.0,
                        speedPrefix: "Pass 1/2",
                        continuation: continuation
                    )
                    
                    guard !self.isCancelled && status1 == 0 else {
                        continuation.finish()
                        return
                    }
                    
                    let pass2Args = Self.buildTrackExtractionArguments(
                        file: file,
                        track: track,
                        outputURL: outputURL,
                        pass: 2,
                        passLogBaseURL: passLogDir,
                        useHardwareAcceleration: useHardwareAcceleration,
                        binaryCapabilities: binCaps,
                        loudnessMeasurement: loudnessMeasurement
                    )
                    let status2 = await self.runFFmpegProcess(
                        ffmpegPath: ffmpegPath,
                        arguments: pass2Args,
                        duration: duration,
                        progressScale: 0.5,
                        progressOffset: 0.5,
                        speedPrefix: "Pass 2/2",
                        continuation: continuation
                    )
                    
                    if !self.isCancelled && status2 == 0 {
                        continuation.yield(RemuxProgress(progress: 1.0, currentTime: duration, totalTime: duration, speed: "Done"))
                    }
                } else {
                    let args = Self.buildTrackExtractionArguments(
                        file: file,
                        track: track,
                        outputURL: outputURL,
                        useHardwareAcceleration: useHardwareAcceleration,
                        binaryCapabilities: binCaps,
                        loudnessMeasurement: loudnessMeasurement
                    )
                    let status = await self.runFFmpegProcess(
                        ffmpegPath: ffmpegPath,
                        arguments: args,
                        duration: duration,
                        progressScale: 1.0,
                        progressOffset: 0.0,
                        speedPrefix: nil,
                        continuation: continuation
                    )
                    
                    if !self.isCancelled && status == 0 {
                        continuation.yield(RemuxProgress(progress: 1.0, currentTime: duration, totalTime: duration, speed: "Done"))
                    }
                }
                
                continuation.finish()
            }
        }
    }
    
    public func cancel() {
        self.isCancelled = true
        if let nativeEngine = activeNativeEngine {
            activeNativeEngine = nil
            Task { await nativeEngine.cancel() }
        }
        for (_, proc) in activeProcesses {
            if proc.isRunning {
                proc.terminate()
            }
        }
        activeProcesses.removeAll()
    }
}

// MARK: - Segmented Progress Aggregator

private actor SegmentedProgressAggregator {
    private let boundaries: [VideoSegmentBoundary]
    private let totalDuration: Double
    private let segmentCount: Int
    private let phaseLabel: String
    private let notice: String?
    private let executionTierLabel: String?
    
    private var chunkTimes: [Int: Double] = [:]
    private var chunkFPS: [Int: Double] = [:]
    private var chunkSpeeds: [Int: Double] = [:]
    private var chunkFrames: [Int: Int64] = [:]
    private var chunkBitrateKbps: [Int: Double] = [:]
    private var completedChunks: Set<Int> = []
    private var lastEmitTime: ContinuousClock.Instant?
    
    init(
        boundaries: [VideoSegmentBoundary],
        totalDuration: Double,
        segmentCount: Int,
        phaseLabel: String,
        notice: String?,
        executionTierLabel: String? = nil
    ) {
        self.boundaries = boundaries
        self.totalDuration = max(0.01, totalDuration)
        self.segmentCount = segmentCount
        self.phaseLabel = phaseLabel
        self.notice = notice
        self.executionTierLabel = executionTierLabel
    }
    
    func updateChunk(index: Int, progress: RemuxProgress) -> RemuxProgress? {
        guard !completedChunks.contains(index) else { return nil }
        let maxDur = index < boundaries.count ? boundaries[index].expectedDuration : progress.totalTime
        chunkTimes[index] = min(maxDur, max(0, progress.currentTime))
        chunkFPS[index] = progress.fps
        chunkFrames[index] = progress.frame
        
        let spdClean = progress.speed.replacingOccurrences(of: "x", with: "")
        if let spdVal = Double(spdClean), spdVal > 0 {
            chunkSpeeds[index] = spdVal
        }
        if let kbps = Self.parseBitrateKbps(progress.bitrate) {
            chunkBitrateKbps[index] = kbps
        }
        
        let now = ContinuousClock.now
        if let last = lastEmitTime, now - last < .milliseconds(120) {
            return nil
        }
        lastEmitTime = now
        return buildAggregate()
    }
    
    func markChunkCompleted(index: Int) -> RemuxProgress? {
        completedChunks.insert(index)
        if index < boundaries.count {
            chunkTimes[index] = boundaries[index].expectedDuration
        }
        chunkSpeeds[index] = 0
        chunkFPS[index] = 0
        lastEmitTime = ContinuousClock.now
        return buildAggregate()
    }
    
    private func buildAggregate() -> RemuxProgress {
        let doneTime = min(totalDuration, chunkTimes.values.reduce(0, +))
        let scaledFraction = min(0.92, (doneTime / totalDuration) * 0.92)
        let activeFPS = chunkFPS.values.reduce(0, +)
        let activeSpeed = chunkSpeeds.values.reduce(0, +)
        let totalFrames = chunkFrames.values.reduce(0, +)
        
        let speedDisplay = activeSpeed > 0.05
            ? String(format: "%.2fx", activeSpeed)
            : "Encoding..."
        let eta: Double? = activeSpeed > 0.05
            ? max(0, (totalDuration - doneTime) / activeSpeed)
            : nil
        
        let totalKbps = chunkBitrateKbps.values.reduce(0, +)
        let avgKbps = chunkBitrateKbps.isEmpty ? 0 : (totalKbps / Double(chunkBitrateKbps.count))
        let bitrateDisplay: String
        if avgKbps >= 1000.0 {
            bitrateDisplay = String(format: "%.1f Mbits/s", avgKbps / 1000.0)
        } else if avgKbps > 0 {
            bitrateDisplay = String(format: "%.0f kbits/s", avgKbps)
        } else {
            bitrateDisplay = ""
        }
        
        return RemuxProgress(
            progress: scaledFraction,
            currentTime: doneTime,
            totalTime: totalDuration,
            fps: activeFPS,
            speed: speedDisplay,
            bitrate: bitrateDisplay,
            frame: totalFrames,
            remainingSeconds: eta,
            activeSegments: segmentCount,
            phaseLabel: phaseLabel,
            notice: notice,
            executionTierLabel: executionTierLabel
        )
    }
    
    private static func parseBitrateKbps(_ raw: String) -> Double? {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasSuffix("kbits/s") {
            return Double(lower.replacingOccurrences(of: "kbits/s", with: ""))
        }
        if lower.hasSuffix("mbits/s"), let val = Double(lower.replacingOccurrences(of: "mbits/s", with: "")) {
            return val * 1000.0
        }
        return nil
    }
}
