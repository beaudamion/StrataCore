import Foundation

public enum RemuxError: LocalizedError {
    case ffmpegNotFound
    case noTracksSelected
    case executionFailed(String)
    case cancelled
    
    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "ffmpeg binary not found. Please bundle static binaries or check configuration."
        case .noTracksSelected:
            return "Please select at least one video, audio, or subtitle track to multiplex."
        case .executionFailed(let msg):
            return "Remuxing failed: \(msg)"
        case .cancelled:
            return "Process was cancelled."
        }
    }
}

public actor RemuxEngine {
    private var activeProcess: Process?
    private var isCancelled: Bool = false
    
    public init() {}
    
    /// Builds ffmpeg arguments array based on MediaFile, RemuxOptions, and selected tracks.
    public static func buildArguments(
        for file: MediaFile,
        options: RemuxOptions,
        pass: Int? = nil,
        passLogBaseURL: URL? = nil
    ) throws -> [String] {
        let selectedTracks = file.tracks.filter { $0.isSelected }
        guard !selectedTracks.isEmpty else {
            throw RemuxError.noTracksSelected
        }
        
        let isPass1 = (pass == 1)
        let activeTracks = isPass1 ? selectedTracks.filter { $0.mediaType == .video } : selectedTracks
        
        var args: [String] = ["-y", "-hide_banner"]
        
        // Input 0: Primary source file
        args += ["-i", file.url.path]
        
        // Extra inputs: External subtitle or audio files
        var externalInputMap: [URL: Int] = [:]
        var nextInputIndex = 1
        
        for track in activeTracks where track.isExternal {
            if let extURL = track.externalURL {
                if externalInputMap[extURL] == nil {
                    externalInputMap[extURL] = nextInputIndex
                    nextInputIndex += 1
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
                    passLogBaseURL: passLogBaseURL
                )
                videoOutIdx += 1
                
            case .audio:
                args += audioEncoderArguments(for: track, streamSpecifier: ":a:\(audioOutIdx)")
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
        
        // FastStart (moov atom before mdat for instant streaming/seeking)
        if isMP4Like && options.fastStart {
            args += ["-movflags", "+faststart"]
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
        passLogBaseURL: URL? = nil
    ) -> [String] {
        var args = ["-y", "-hide_banner"]
        
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
                passLogBaseURL: passLogBaseURL
            )
        case .audio:
            args += audioEncoderArguments(for: track, streamSpecifier: ":a:0")
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
            args += ["-movflags", "+faststart"]
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
    
    private static func videoEncoderArguments(
        for track: MediaTrack,
        streamSpecifier spec: String,
        isMP4Like: Bool,
        pass: Int?,
        passLogBaseURL: URL?
    ) -> [String] {
        guard track.action != .copy else {
            return ["-c\(spec)", "copy"]
        }
        
        let cfg = track.videoConfig
        var args: [String] = []
        let useTwoPassEncoder = (cfg.multiPass || pass != nil) && (track.action == .transcodeH264_VT || track.action == .transcodeHEVC_VT)
        let safeSpecTag = spec.replacingOccurrences(of: ":", with: "_")
        let pfLower = track.pixelFormat?.lowercased() ?? ""
        let hasAlpha = pfLower.contains("yuva") || pfLower.contains("rgba") || pfLower.contains("bgra") || pfLower.contains("argb") || pfLower.contains("abgr") || pfLower.contains("ayuv") || pfLower.contains("gbrap")
        
        var filterParts: [String] = []
        var setparamsParts: [String] = []
        
        switch track.action {
        case .transcodeH264_VT:
            let validProfiles = ["baseline", "constrained_baseline", "main", "high", "constrained_high", "extended"]
            let rawProfile = cfg.profile?.lowercased()
            let validProf = rawProfile.flatMap { validProfiles.contains($0) ? $0 : nil }
            let isBaseline: Bool
            
            if useTwoPassEncoder {
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
                args += ["-b\(spec)", resolvedMultiPassBitrate(for: track)]
                
                if let kf = cfg.keyFrameInterval, kf > 0 {
                    args += ["-g\(spec)", "\(kf)"]
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
                        filterParts.append("yadif=0:-1:1")
                        setparamsParts.append("field_mode=prog")
                        args += ["-field_order\(spec)", "progressive"]
                    case .auto, .none:
                        break
                    }
                } else {
                    filterParts.append("yadif=0:-1:1")
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
                args += ["-pix_fmt\(spec)", "yuv420p"]
                if let br = normalizedBitrate(cfg.bitrate) {
                    args += ["-b\(spec)", br]
                }
                if let kf = cfg.keyFrameInterval, kf > 0 {
                    args += ["-g\(spec)", "\(kf)"]
                }
                // VideoToolbox H.264 outputs progressive frames cleanly
                filterParts.append("yadif=0:-1:1")
                setparamsParts.append("field_mode=prog")
                args += ["-field_order\(spec)", "progressive"]
            }
            
        case .transcodeHEVC_VT:
            let validProfiles = ["main", "main10", "main422", "main42210"]
            let rawProfile = cfg.profile?.lowercased()
            let validProf = rawProfile.flatMap { validProfiles.contains($0) ? $0 : nil }
            let useX265 = useTwoPassEncoder || (validProf == "main422")
            
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
                    args += ["-b\(spec)", resolvedMultiPassBitrate(for: track)]
                } else if let br = normalizedBitrate(cfg.bitrate) {
                    args += ["-b\(spec)", br]
                }
                
                if let kf = cfg.keyFrameInterval, kf > 0 {
                    args += ["-g\(spec)", "\(kf)"]
                }
                
                if let p = pass, (p == 1 || p == 2) {
                    if let baseURL = passLogBaseURL {
                        let statsFile = baseURL.appendingPathComponent("x265\(safeSpecTag).log").path
                        args += ["-x265-params\(spec)", "pass=\(p):stats=\(statsFile)"]
                    } else {
                        args += ["-x265-params\(spec)", "pass=\(p)"]
                    }
                }
            } else {
                args += ["-c\(spec)", "hevc_videotoolbox"]
                let alphaEligible = (validProf == nil || validProf == "main") && cfg.preserveAlpha && hasAlpha
                
                if alphaEligible {
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
                
                args += ["-bf\(spec)", cfg.allowFrameReordering ? "2" : "0"]
                
                if let br = normalizedBitrate(cfg.bitrate) {
                    args += ["-b\(spec)", br]
                }
                if let kf = cfg.keyFrameInterval, kf > 0 {
                    args += ["-g\(spec)", "\(kf)"]
                }
            }
            
            // HEVC enforces progressive frames cleanly
            filterParts.append("yadif=0:-1:1")
            setparamsParts.append("field_mode=prog")
            args += ["-field_order\(spec)", "progressive"]
            
            if isMP4Like && pass != 1 {
                args += ["-tag\(spec)", "hvc1"]
            }
            
        case .transcodeProRes:
            let validProResProfiles = ["0", "1", "2", "3", "4", "5"]
            let profile = cfg.profile.flatMap { validProResProfiles.contains($0) ? $0 : nil } ?? "2"
            let canPreserveAlpha = (profile == "4" || profile == "5") && cfg.preserveAlpha && hasAlpha
            let pixFmt = (profile == "4" || profile == "5")
                ? (canPreserveAlpha ? "yuva444p10le" : "yuv444p10le")
                : "yuv422p10le"
            args += ["-c\(spec)", "prores_ks", "-profile\(spec)", profile, "-pix_fmt\(spec)", pixFmt]
            
            switch cfg.fieldOrder {
            case .topFirst:
                args += ["-flags\(spec)", "+ilme+ildct", "-field_order\(spec)", "tt"]
                setparamsParts.append("field_mode=tff")
            case .bottomFirst:
                args += ["-flags\(spec)", "+ilme+ildct", "-field_order\(spec)", "bb"]
                setparamsParts.append("field_mode=bff")
            case .progressive:
                filterParts.append("yadif=0:-1:1")
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
        
        if let cs = cfg.colorSpace,
           cs != .auto,
           let p = cs.ffPrimaries,
           let t = cs.ffTransfer,
           let m = cs.ffMatrix {
            setparamsParts += [
                "color_primaries=\(p)",
                "color_trc=\(t)",
                "colorspace=\(m)"
            ]
            args += [
                "-color_primaries\(spec)", p,
                "-color_trc\(spec)", t,
                "-colorspace\(spec)", m
            ]
        }
        
        if !setparamsParts.isEmpty {
            filterParts.append("setparams=" + setparamsParts.joined(separator: ":"))
        }
        if !filterParts.isEmpty {
            args += ["-filter\(spec)", filterParts.joined(separator: ",")]
        }
        
        return args
    }
    
    private static func audioEncoderArguments(
        for track: MediaTrack,
        streamSpecifier spec: String
    ) -> [String] {
        var args: [String] = []
        switch track.action {
        case .copy:
            return ["-c\(spec)", "copy"]
        case .transcodeAAC_Stereo, .transcodeAAC_51:
            let br = track.audioConfig.bitrate.isEmpty ? (track.action == .transcodeAAC_51 ? "384k" : "192k") : track.audioConfig.bitrate
            args += ["-c\(spec)", "aac", "-b\(spec)", br]
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
        
        // Channel downmixing / remixing if specified
        if let ch = track.audioConfig.channels {
            args += ["-ac\(spec)", "\(ch)"]
        }
        // Custom sample rate if specified
        if let sr = track.audioConfig.sampleRate {
            args += ["-ar\(spec)", sr]
        }
        
        return args
    }
    
    private func runFFmpegProcess(
        ffmpegPath: String,
        arguments: [String],
        duration: Double,
        progressScale: Double,
        progressOffset: Double,
        speedPrefix: String?,
        continuation: AsyncStream<RemuxProgress>.Continuation
    ) async -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments
        
        let stderrPipe = Pipe()
        process.standardOutput = Pipe() // discard stdout
        process.standardError = stderrPipe
        
        self.activeProcess = process
        
        do {
            try process.run()
        } catch {
            self.activeProcess = nil
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
                                remainingSeconds: update.remainingSeconds
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
        
        process.waitUntilExit()
        self.activeProcess = nil
        return process.terminationStatus
    }
    
    /// Executes the remux job and yields progress updates asynchronously.
    public func run(
        file: MediaFile,
        options: RemuxOptions,
        ffmpegPathOverride: String? = nil
    ) -> AsyncStream<RemuxProgress> {
        self.isCancelled = false
        
        return AsyncStream { continuation in
            _ = Task {
                guard let ffmpegPath = ffmpegPathOverride ?? FFmpegLocator.shared.ffmpegPath else {
                    continuation.finish()
                    return
                }
                
                let selectedTracks = file.tracks.filter { $0.isSelected }
                let needsTwoPass = selectedTracks.contains {
                    $0.mediaType == .video &&
                    $0.videoConfig.multiPass &&
                    ($0.action == .transcodeH264_VT || $0.action == .transcodeHEVC_VT)
                }
                
                // Ensure parent directory of output exists
                let parentDir = options.outputURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                
                let duration = file.duration
                
                if needsTwoPass {
                    let passLogDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("strata_2pass_\(UUID().uuidString)")
                    try? FileManager.default.createDirectory(at: passLogDir, withIntermediateDirectories: true)
                    defer {
                        try? FileManager.default.removeItem(at: passLogDir)
                    }
                    
                    let pass1Args: [String]
                    let pass2Args: [String]
                    do {
                        pass1Args = try Self.buildArguments(for: file, options: options, pass: 1, passLogBaseURL: passLogDir)
                        pass2Args = try Self.buildArguments(for: file, options: options, pass: 2, passLogBaseURL: passLogDir)
                    } catch {
                        continuation.finish()
                        return
                    }
                    
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
                    let arguments: [String]
                    do {
                        arguments = try Self.buildArguments(for: file, options: options)
                    } catch {
                        continuation.finish()
                        return
                    }
                    
                    let status = await self.runFFmpegProcess(
                        ffmpegPath: ffmpegPath,
                        arguments: arguments,
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
    
    /// Extracts a single track into a dedicated standalone file.
    public func extractTrack(
        file: MediaFile,
        track: MediaTrack,
        outputURL: URL,
        ffmpegPathOverride: String? = nil
    ) -> AsyncStream<RemuxProgress> {
        self.isCancelled = false
        
        return AsyncStream { continuation in
            _ = Task {
                guard let ffmpegPath = ffmpegPathOverride ?? FFmpegLocator.shared.ffmpegPath else {
                    continuation.finish()
                    return
                }
                
                let needsTwoPass = track.mediaType == .video &&
                    track.videoConfig.multiPass &&
                    (track.action == .transcodeH264_VT || track.action == .transcodeHEVC_VT)
                
                // Ensure parent directory exists
                try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                
                let duration = file.duration
                
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
                        passLogBaseURL: passLogDir
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
                        passLogBaseURL: passLogDir
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
                    let args = Self.buildTrackExtractionArguments(file: file, track: track, outputURL: outputURL)
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
        if let proc = activeProcess, proc.isRunning {
            proc.terminate()
        }
        self.activeProcess = nil
    }
}
