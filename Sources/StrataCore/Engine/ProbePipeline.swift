import Foundation

public enum ProbeError: LocalizedError {
    case ffprobeNotFound
    case executionFailed(String)
    case decodingFailed(String)
    case fileNotFound(URL)
    
    public var errorDescription: String? {
        switch self {
        case .ffprobeNotFound:
            return "ffprobe binary not found. Please install ffmpeg or bundle static binaries."
        case .executionFailed(let msg):
            return "ffprobe execution failed: \(msg)"
        case .decodingFailed(let msg):
            return "Failed to parse media probe metadata: \(msg)"
        case .fileNotFound(let url):
            return "Media file not found at: \(url.path)"
        }
    }
}

// MARK: - Decodable FFprobe JSON Schema

private struct FFprobeOutput: Decodable {
    let streams: [FFprobeStream]?
    let format: FFprobeFormat?
    let chapters: [FFprobeChapter]?
}

private struct FFprobeStream: Decodable {
    let index: Int
    let codec_name: String?
    let codec_long_name: String?
    let codec_type: String?
    let profile: String?
    let width: Int?
    let height: Int?
    let r_frame_rate: String?
    let avg_frame_rate: String?
    let pix_fmt: String?
    let color_space: String?
    let channels: Int?
    let channel_layout: String?
    let sample_rate: String?
    let bit_rate: String?
    let disposition: [String: Int]?
    let tags: [String: String]?
}

private struct FFprobeFormat: Decodable {
    let filename: String?
    let nb_streams: Int?
    let format_name: String?
    let format_long_name: String?
    let duration: String?
    let size: String?
    let bit_rate: String?
    let tags: [String: String]?
}

private struct FFprobeChapter: Decodable {
    let id: Int
    let start_time: String?
    let end_time: String?
    let tags: [String: String]?
}

// MARK: - Probe Pipeline

public final class ProbePipeline {
    public static let shared = ProbePipeline()
    public static let supportedSubtitleExtensions: [String] = ["srt", "ass", "ssa", "vtt", "sub", "idx"]
    private static let jsonDecoder = JSONDecoder()
    
    public init() {}
    
    /// Probes a given media file URL using `ffprobe` and returns a deserialized `MediaFile` model.
    public func probe(fileURL: URL) async throws -> MediaFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ProbeError.fileNotFound(fileURL)
        }
        
        guard let ffprobePath = FFmpegLocator.shared.ffprobePath else {
            throw ProbeError.ffprobeNotFound
        }
        
        let arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            "-show_chapters",
            fileURL.path
        ]
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = arguments
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        do {
            try process.run()
        } catch {
            throw ProbeError.executionFailed(error.localizedDescription)
        }
        
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errString = String(data: errData, encoding: .utf8) ?? "Exit code \(process.terminationStatus)"
            throw ProbeError.executionFailed(errString)
        }
        
        let probeResult: FFprobeOutput
        do {
            probeResult = try Self.jsonDecoder.decode(FFprobeOutput.self, from: data)
        } catch {
            throw ProbeError.decodingFailed(error.localizedDescription)
        }
        
        return buildMediaFile(from: probeResult, fileURL: fileURL)
    }
    
    /// Probes an external file (video, audio, or subtitle) and returns its streams as external MediaTrack objects.
    public func probeExternalTracks(fileURL: URL) async throws -> [MediaTrack] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ProbeError.fileNotFound(fileURL)
        }
        
        let ext = fileURL.pathExtension.lowercased()
        let isSubtitleExt = Self.supportedSubtitleExtensions.contains(ext)
        
        // 1. Try standard probe
        do {
            let media = try await probe(fileURL: fileURL)
            if !media.tracks.isEmpty {
                return media.tracks.map { tr in
                    var t = tr
                    t.isExternal = true
                    t.externalURL = fileURL
                    t.isSelected = true
                    if t.title.isEmpty {
                        t.title = fileURL.deletingPathExtension().lastPathComponent
                    }
                    return t
                }
            }
        } catch {
            if !isSubtitleExt {
                throw error
            }
        }
        
        // 2. Fallback for standalone subtitle files if probe failed or returned no streams
        if isSubtitleExt {
            let subTrack = try await probeSubtitle(fileURL: fileURL, streamIndex: 0)
            var t = subTrack
            t.isExternal = true
            t.externalURL = fileURL
            t.isSelected = true
            if t.title.isEmpty {
                t.title = fileURL.deletingPathExtension().lastPathComponent
            }
            return [t]
        }
        
        return []
    }
    
    /// Probes an external subtitle file (.srt, .ass, etc.) and creates a MediaTrack representation.
    public func probeSubtitle(fileURL: URL, streamIndex: Int) async throws -> MediaTrack {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ProbeError.fileNotFound(fileURL)
        }
        
        let ext = fileURL.pathExtension.lowercased()
        let fallbackCodec: String
        let fallbackType: TrackAction
        switch ext {
        case "srt":
            fallbackCodec = "subrip"
            fallbackType = .copy
        case "ass", "ssa":
            fallbackCodec = "ass"
            fallbackType = .copy
        case "vtt":
            fallbackCodec = "webvtt"
            fallbackType = .copy
        default:
            fallbackCodec = ext
            fallbackType = .copy
        }
        
        // Try probing with ffprobe if available
        if let ffprobePath = FFmpegLocator.shared.ffprobePath {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobePath)
            process.arguments = ["-v", "quiet", "-print_format", "json", "-show_streams", fileURL.path]
            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            
            if (try? process.run()) != nil {
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if let output = try? JSONDecoder().decode(FFprobeOutput.self, from: data),
                   let stream = output.streams?.first {
                    let lang = stream.tags?["language"] ?? "und"
                    let title = stream.tags?["title"] ?? fileURL.deletingPathExtension().lastPathComponent
                    let codec = stream.codec_name ?? fallbackCodec
                    return MediaTrack(
                        streamIndex: streamIndex,
                        mediaType: .subtitle,
                        codecName: codec,
                        codecLongName: stream.codec_long_name,
                        language: lang,
                        title: title,
                        isSelected: true,
                        action: fallbackType,
                        isExternal: true,
                        externalURL: fileURL
                    )
                }
            }
        }
        
        // Fallback without ffprobe
        return MediaTrack(
            streamIndex: streamIndex,
            mediaType: .subtitle,
            codecName: fallbackCodec,
            language: "und",
            title: fileURL.deletingPathExtension().lastPathComponent,
            isSelected: true,
            action: fallbackType,
            isExternal: true,
            externalURL: fileURL
        )
    }
    
    private func buildMediaFile(from output: FFprobeOutput, fileURL: URL) -> MediaFile {
        let fmt = output.format
        let duration = Double(fmt?.duration ?? "0") ?? 0.0
        let size = Int64(fmt?.size ?? "0") ?? (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        let bitRate = Int64(fmt?.bit_rate ?? "0") ?? 0
        let formatName = fmt?.format_name ?? fileURL.pathExtension
        let formatLong = fmt?.format_long_name ?? ""
        let tags = fmt?.tags ?? [:]
        
        // Build tracks
        var tracks: [MediaTrack] = []
        if let streams = output.streams {
            for stream in streams {
                let mType: MediaType
                switch stream.codec_type?.lowercased() {
                case "video": mType = .video
                case "audio": mType = .audio
                case "subtitle": mType = .subtitle
                case "attachment": mType = .attachment
                case "data": mType = .data
                default: mType = .other
                }
                
                let codecName = stream.codec_name ?? "unknown"
                let lang = stream.tags?["language"] ?? stream.tags?["LANGUAGE"] ?? "und"
                let title = stream.tags?["title"] ?? stream.tags?["TITLE"] ?? stream.tags?["handler_name"] ?? ""
                
                let isDef = (stream.disposition?["default"] ?? 0) != 0
                let isFrc = (stream.disposition?["forced"] ?? 0) != 0
                
                let fpsString = formatFrameRate(stream.avg_frame_rate ?? stream.r_frame_rate)
                
                let track = MediaTrack(
                    streamIndex: stream.index,
                    mediaType: mType,
                    codecName: codecName,
                    codecLongName: stream.codec_long_name,
                    profile: stream.profile,
                    width: stream.width,
                    height: stream.height,
                    frameRate: fpsString,
                    pixelFormat: stream.pix_fmt,
                    colorSpace: stream.color_space,
                    channels: stream.channels,
                    channelLayout: stream.channel_layout,
                    sampleRate: stream.sample_rate,
                    bitRate: Int64(stream.bit_rate ?? "0"),
                    language: lang,
                    title: title,
                    isDefault: isDef,
                    isForced: isFrc,
                    isSelected: (mType == .video || mType == .audio || mType == .subtitle),
                    action: .copy,
                    isExternal: false,
                    externalURL: nil
                )
                tracks.append(track)
            }
        }
        
        // Build chapters
        var chapters: [MediaChapter] = []
        if let rawChapters = output.chapters {
            for ch in rawChapters {
                let start = Double(ch.start_time ?? "0") ?? 0
                let end = Double(ch.end_time ?? "0") ?? 0
                let title = ch.tags?["title"] ?? "Chapter \(ch.id + 1)"
                chapters.append(MediaChapter(id: ch.id, startTime: start, endTime: end, title: title))
            }
        }
        
        return MediaFile(
            url: fileURL,
            filename: fileURL.lastPathComponent,
            fileSize: size,
            containerFormat: formatName,
            containerLongName: formatLong,
            duration: duration,
            overallBitRate: bitRate,
            tags: tags,
            tracks: tracks,
            chapters: chapters
        )
    }
    
    private func formatFrameRate(_ rate: String?) -> String? {
        guard let rate = rate, !rate.isEmpty, rate != "0/0" else { return nil }
        let parts = rate.components(separatedBy: "/")
        if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den > 0 {
            let val = num / den
            if abs(val - 23.976) < 0.01 { return "23.98 fps" }
            if abs(val - 24.0) < 0.01 { return "24 fps" }
            if abs(val - 25.0) < 0.01 { return "25 fps" }
            if abs(val - 29.97) < 0.01 { return "29.97 fps" }
            if abs(val - 30.0) < 0.01 { return "30 fps" }
            if abs(val - 50.0) < 0.01 { return "50 fps" }
            if abs(val - 59.94) < 0.01 { return "59.94 fps" }
            if abs(val - 60.0) < 0.01 { return "60 fps" }
            return String(format: "%.2f fps", val)
        }
        return rate
    }
}
