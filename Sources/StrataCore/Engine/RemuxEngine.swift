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
        options: RemuxOptions
    ) throws -> [String] {
        let selectedTracks = file.tracks.filter { $0.isSelected }
        guard !selectedTracks.isEmpty else {
            throw RemuxError.noTracksSelected
        }
        
        var args: [String] = ["-y", "-hide_banner"]
        
        // Input 0: Primary source file
        args += ["-i", file.url.path]
        
        // Extra inputs: External subtitle or audio files
        var externalInputMap: [URL: Int] = [:]
        var nextInputIndex = 1
        
        for track in selectedTracks where track.isExternal {
            if let extURL = track.externalURL {
                if externalInputMap[extURL] == nil {
                    externalInputMap[extURL] = nextInputIndex
                    nextInputIndex += 1
                    args += ["-i", extURL.path]
                }
            }
        }
        
        // Map streams
        for track in selectedTracks {
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
        
        for track in selectedTracks {
            switch track.mediaType {
            case .video:
                switch track.action {
                case .copy:
                    args += ["-c:v:\(videoOutIdx)", "copy"]
                case .transcodeH264_VT:
                    args += ["-c:v:\(videoOutIdx)", "h264_videotoolbox", "-b:v", "6000k"]
                case .transcodeHEVC_VT:
                    args += ["-c:v:\(videoOutIdx)", "hevc_videotoolbox", "-b:v", "4500k"]
                case .transcodeProRes:
                    args += ["-c:v:\(videoOutIdx)", "prores_ks", "-profile:v", "2"]
                default:
                    args += ["-c:v:\(videoOutIdx)", "copy"]
                }
                videoOutIdx += 1
                
            case .audio:
                switch track.action {
                case .copy:
                    args += ["-c:a:\(audioOutIdx)", "copy"]
                case .transcodeAAC_Stereo, .transcodeAAC_51:
                    let br = track.audioConfig.bitrate.isEmpty ? (track.action == .transcodeAAC_51 ? "384k" : "192k") : track.audioConfig.bitrate
                    args += ["-c:a:\(audioOutIdx)", "aac", "-b:a:\(audioOutIdx)", br]
                case .transcodeMP3:
                    args += ["-c:a:\(audioOutIdx)", "libmp3lame"]
                    if track.audioConfig.isVBR {
                        let q = track.audioConfig.bitrate == "V0" ? "0" : (track.audioConfig.bitrate == "V2" ? "2" : "4")
                        args += ["-q:a:\(audioOutIdx)", q]
                    } else {
                        args += ["-b:a:\(audioOutIdx)", track.audioConfig.bitrate.isEmpty ? "320k" : track.audioConfig.bitrate]
                    }
                case .transcodeALAC:
                    args += ["-c:a:\(audioOutIdx)", "alac"]
                    if track.audioConfig.bitDepth == "24" {
                        args += ["-sample_fmt:a:\(audioOutIdx)", "s32p"]
                    } else if track.audioConfig.bitDepth == "16" {
                        args += ["-sample_fmt:a:\(audioOutIdx)", "s16p"]
                    }
                case .transcodeAC3_51:
                    let br = track.audioConfig.bitrate.isEmpty ? "640k" : track.audioConfig.bitrate
                    args += ["-c:a:\(audioOutIdx)", "ac3", "-b:a:\(audioOutIdx)", br]
                case .transcodeEAC3_51:
                    let br = track.audioConfig.bitrate.isEmpty ? "640k" : track.audioConfig.bitrate
                    args += ["-c:a:\(audioOutIdx)", "eac3", "-b:a:\(audioOutIdx)", br]
                case .transcodeOpus:
                    let br = track.audioConfig.bitrate.isEmpty ? "510k" : track.audioConfig.bitrate
                    args += ["-c:a:\(audioOutIdx)", "libopus", "-b:a:\(audioOutIdx)", br]
                case .transcodeFLAC:
                    args += ["-c:a:\(audioOutIdx)", "flac"]
                    if track.audioConfig.bitDepth == "24" {
                        args += ["-sample_fmt:a:\(audioOutIdx)", "s32"]
                    } else if track.audioConfig.bitDepth == "16" {
                        args += ["-sample_fmt:a:\(audioOutIdx)", "s16"]
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
                    args += ["-c:a:\(audioOutIdx)", pcmCodec]
                case .transcodeAIFF:
                    let pcmCodec: String
                    switch track.audioConfig.bitDepth {
                    case "32float": pcmCodec = "pcm_f32be"
                    case "32": pcmCodec = "pcm_s32be"
                    case "24": pcmCodec = "pcm_s24be"
                    case "8": pcmCodec = "pcm_s8"
                    default: pcmCodec = "pcm_s16be"
                    }
                    args += ["-c:a:\(audioOutIdx)", pcmCodec]
                default:
                    args += ["-c:a:\(audioOutIdx)", "copy"]
                }
                
                // Channel downmixing / remixing if specified
                if let ch = track.audioConfig.channels {
                    args += ["-ac:a:\(audioOutIdx)", "\(ch)"]
                }
                // Custom sample rate if specified
                if let sr = track.audioConfig.sampleRate {
                    args += ["-ar:a:\(audioOutIdx)", sr]
                }
                
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
            
            totalOutIdx += 1
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
    
    /// Executes the remux job and yields progress updates asynchronously.
    public func run(
        file: MediaFile,
        options: RemuxOptions
    ) -> AsyncStream<RemuxProgress> {
        self.isCancelled = false
        
        return AsyncStream { continuation in
            _ = Task {
                guard let ffmpegPath = FFmpegLocator.shared.ffmpegPath else {
                    continuation.finish()
                    return
                }
                
                let arguments: [String]
                do {
                    arguments = try Self.buildArguments(for: file, options: options)
                } catch {
                    continuation.finish()
                    return
                }
                
                // Ensure parent directory of output exists
                let parentDir = options.outputURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpegPath)
                process.arguments = arguments
                
                let stderrPipe = Pipe()
                process.standardOutput = Pipe() // discard stdout
                process.standardError = stderrPipe
                
                self.activeProcess = process
                
                let fileHandle = stderrPipe.fileHandleForReading
                
                do {
                    try process.run()
                } catch {
                    continuation.finish()
                    return
                }
                
                // Read progress in background using an allocation-efficient line buffer
                let duration = file.duration
                var lineBuffer = Data()
                lineBuffer.reserveCapacity(256)
                
                for try await byteData in fileHandle.bytes {
                    if self.isCancelled { break }
                    
                    if byteData == 0x0A || byteData == 0x0D {
                        if !lineBuffer.isEmpty {
                            if let line = String(data: lineBuffer, encoding: .utf8),
                               let update = MediaFormatters.parseFFmpegProgress(line: line, totalDuration: duration) {
                                continuation.yield(update)
                            }
                            lineBuffer.removeAll(keepingCapacity: true)
                        }
                    } else {
                        lineBuffer.append(byteData)
                    }
                }
                
                process.waitUntilExit()
                
                if !self.isCancelled && process.terminationStatus == 0 {
                    // Final 100% progress
                    continuation.yield(RemuxProgress(progress: 1.0, currentTime: duration, totalTime: duration, speed: "Done"))
                }
                
                self.activeProcess = nil
                continuation.finish()
            }
        }
    }
    
    /// Extracts a single track into a dedicated standalone file.
    public func extractTrack(
        file: MediaFile,
        track: MediaTrack,
        outputURL: URL
    ) -> AsyncStream<RemuxProgress> {
        self.isCancelled = false
        
        return AsyncStream { continuation in
            _ = Task {
                guard let ffmpegPath = FFmpegLocator.shared.ffmpegPath else {
                    continuation.finish()
                    return
                }
                
                var args = ["-y", "-hide_banner"]
                
                if track.isExternal, let extURL = track.externalURL {
                    args += ["-i", extURL.path, "-map", "0:\(track.streamIndex)"]
                } else {
                    args += ["-i", file.url.path, "-map", "0:\(track.streamIndex)"]
                }
                
                // Codec configuration for extraction
                switch track.action {
                case .copy:
                    args += ["-c", "copy"]
                case .transcodeH264_VT:
                    args += ["-c:v", "h264_videotoolbox", "-b:v", "6000k"]
                case .transcodeHEVC_VT:
                    args += ["-c:v", "hevc_videotoolbox", "-b:v", "4500k"]
                case .transcodeProRes:
                    args += ["-c:v", "prores_ks", "-profile:v", "2"]
                case .transcodeMP3:
                    args += ["-c:a", "libmp3lame"]
                    if track.audioConfig.isVBR {
                        let q = track.audioConfig.bitrate == "V0" ? "0" : (track.audioConfig.bitrate == "V2" ? "2" : "4")
                        args += ["-q:a", q]
                    } else {
                        args += ["-b:a", track.audioConfig.bitrate.isEmpty ? "320k" : track.audioConfig.bitrate]
                    }
                case .transcodeALAC:
                    args += ["-c:a", "alac"]
                    if track.audioConfig.bitDepth == "24" {
                        args += ["-sample_fmt", "s32p"]
                    } else if track.audioConfig.bitDepth == "16" {
                        args += ["-sample_fmt", "s16p"]
                    }
                case .transcodeAAC_Stereo, .transcodeAAC_51:
                    let br = track.audioConfig.bitrate.isEmpty ? (track.action == .transcodeAAC_51 ? "384k" : "192k") : track.audioConfig.bitrate
                    args += ["-c:a", "aac", "-b:a", br]
                case .transcodeAC3_51:
                    let br = track.audioConfig.bitrate.isEmpty ? "640k" : track.audioConfig.bitrate
                    args += ["-c:a", "ac3", "-b:a", br]
                case .transcodeEAC3_51:
                    let br = track.audioConfig.bitrate.isEmpty ? "640k" : track.audioConfig.bitrate
                    args += ["-c:a", "eac3", "-b:a", br]
                case .transcodeOpus:
                    let br = track.audioConfig.bitrate.isEmpty ? "510k" : track.audioConfig.bitrate
                    args += ["-c:a", "libopus", "-b:a", br]
                case .transcodeFLAC:
                    args += ["-c:a", "flac"]
                    if track.audioConfig.bitDepth == "24" {
                        args += ["-sample_fmt", "s32"]
                    } else if track.audioConfig.bitDepth == "16" {
                        args += ["-sample_fmt", "s16"]
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
                    args += ["-c:a", pcmCodec]
                case .transcodeAIFF:
                    let pcmCodec: String
                    switch track.audioConfig.bitDepth {
                    case "32float": pcmCodec = "pcm_f32be"
                    case "32": pcmCodec = "pcm_s32be"
                    case "24": pcmCodec = "pcm_s24be"
                    case "8": pcmCodec = "pcm_s8"
                    default: pcmCodec = "pcm_s16be"
                    }
                    args += ["-c:a", pcmCodec]
                case .transcodeSRT:
                    args += ["-c:s", "subrip"]
                default:
                    args += ["-c", "copy"]
                }
                
                if let ch = track.audioConfig.channels, track.mediaType == .audio {
                    args += ["-ac", "\(ch)"]
                }
                if let sr = track.audioConfig.sampleRate, track.mediaType == .audio {
                    args += ["-ar", sr]
                }
                
                // FastStart if m4a/mp4/mov/m4v
                let ext = outputURL.pathExtension.lowercased()
                if ext == "m4a" || ext == "mp4" || ext == "mov" || ext == "m4v" {
                    args += ["-movflags", "+faststart"]
                }
                
                args.append(outputURL.path)
                
                // Ensure parent directory exists
                try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpegPath)
                process.arguments = args
                
                let stderrPipe = Pipe()
                process.standardOutput = Pipe()
                process.standardError = stderrPipe
                self.activeProcess = process
                
                do {
                    try process.run()
                } catch {
                    continuation.finish()
                    return
                }
                
                let fileHandle = stderrPipe.fileHandleForReading
                let duration = file.duration
                var lineBuffer = Data()
                lineBuffer.reserveCapacity(256)
                
                for try await byteData in fileHandle.bytes {
                    if self.isCancelled { break }
                    if byteData == 0x0A || byteData == 0x0D {
                        if !lineBuffer.isEmpty {
                            if let line = String(data: lineBuffer, encoding: .utf8),
                               let update = MediaFormatters.parseFFmpegProgress(line: line, totalDuration: duration) {
                                continuation.yield(update)
                            }
                            lineBuffer.removeAll(keepingCapacity: true)
                        }
                    } else {
                        lineBuffer.append(byteData)
                    }
                }
                
                process.waitUntilExit()
                if !self.isCancelled && process.terminationStatus == 0 {
                    continuation.yield(RemuxProgress(progress: 1.0, currentTime: duration, totalTime: duration, speed: "Done"))
                }
                self.activeProcess = nil
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
