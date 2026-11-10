import Foundation

public enum ProbeError: LocalizedError {
    case ffprobeNotFound
    case fileNotFound(URL)
    case permissionDenied(URL)
    case unsupportedFormat(extension: String)
    case unsupportedImage(extension: String)
    case emptyFile(String)
    case noStreamsFound(String)
    case corruptedMedia(String)
    case executionFailed(String)
    case decodingFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .ffprobeNotFound:
            return "Engine Missing: ffprobe binary not found. Please install ffmpeg or configure paths in Settings."
        case .fileNotFound(let url):
            return "File Not Found: '\(url.lastPathComponent)' could not be located or accessed."
        case .permissionDenied(let url):
            return "Permission Denied: Strata does not have permission to read '\(url.lastPathComponent)'."
        case .unsupportedImage(let ext):
            if ext.isEmpty {
                return "Unsupported Image Format: Static images are not supported. Strata works with video, audio, and subtitle files."
            } else {
                return "Unsupported Image Format: '.\(ext)' is a static image. Strata works with video, audio, and subtitle files."
            }
        case .unsupportedFormat(let ext):
            if ext.isEmpty {
                return "Unsupported File Format: Strata only supports video, audio, and subtitle media files."
            } else {
                return "Unsupported File Format: '.\(ext)' is not a supported media file. Strata works with video, audio, and subtitle files."
            }
        case .emptyFile(let name):
            return "Empty File: '\(name)' contains no data (0 bytes)."
        case .noStreamsFound(let name):
            return "No Media Streams: No playable audio, video, or subtitle tracks were found in '\(name)'."
        case .corruptedMedia(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Corrupted Media: The file structure is damaged, truncated, or unreadable."
            } else {
                return "Corrupted Media: \(trimmed)"
            }
        case .executionFailed(let msg):
            let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Unsupported or Corrupted File: Unable to inspect media streams."
            }
            return "Media Inspection Failed: \(trimmed)"
        case .decodingFailed(let msg):
            return "Corrupted Metadata: Unable to parse stream metadata (\(msg))."
        }
    }
}

// MARK: - Decodable FFprobe JSON Schema

private struct FFprobeOutput: Decodable {
    let streams: [FFprobeStream]?
    let format: FFprobeFormat?
    let chapters: [FFprobeChapter]?
}

private struct FFprobeSideData: Decodable {
    let side_data_type: String?
}

private struct FFprobeStream: Decodable {
    let index: Int
    let codec_name: String?
    let codec_long_name: String?
    let codec_type: String?
    let profile: String?
    let codec_tag_string: String?
    let level: Int?
    let width: Int?
    let height: Int?
    let r_frame_rate: String?
    let avg_frame_rate: String?
    let pix_fmt: String?
    let color_space: String?
    let color_primaries: String?
    let color_transfer: String?
    let color_range: String?
    let chroma_location: String?
    let field_order: String?
    let sample_aspect_ratio: String?
    let display_aspect_ratio: String?
    let bits_per_raw_sample: String?
    let has_b_frames: Int?
    let nb_frames: String?
    let channels: Int?
    let channel_layout: String?
    let sample_rate: String?
    let sample_fmt: String?
    let bits_per_sample: Int?
    let bit_rate: String?
    let disposition: [String: Int]?
    let tags: [String: String]?
    let side_data_list: [FFprobeSideData]?
}

private struct FFprobeFormat: Decodable {
    let filename: String?
    let nb_streams: Int?
    let format_name: String?
    let format_long_name: String?
    let start_time: String?
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
    public static let commonMediaExtensions: Set<String> = [
        // Video containers & streams
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "f4v",
        "ts", "mts", "m2ts", "vob", "ogv", "3gp", "3g2", "asf", "rm", "rmvb",
        "divx", "mpg", "mpeg", "m2v", "m4u", "m4p", "dv", "mxf", "nut", "gif",
        "amv", "y4m",
        // Audio containers & streams
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ac3", "eac3",
        "ec3", "dts", "dtshd", "dtsma", "truehd", "thd", "opus", "ogg", "oga",
        "wma", "alac", "mka", "ape", "wv", "caf", "amr", "pcm", "m4b", "m4r",
        // Subtitle formats
        "srt", "ass", "ssa", "vtt", "sub", "sup", "idx", "smi", "ttml", "dfxp"
    ]
    public static let unsupportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "jif", "jfif", "jfi",
        "heic", "heif", "hif", "tiff", "tif", "bmp", "dib",
        "webp", "svg", "svgz", "ico", "cur", "icns", "avif",
        "psd", "psb", "ai", "eps", "raw", "cr2", "cr3", "nef",
        "nrw", "arw", "srf", "sr2", "orf", "rw2", "pef", "dng",
        "raf", "exr", "hdr", "jp2", "j2k", "jpf", "jpx", "jpm"
    ]
    private static let jsonDecoder = JSONDecoder()
    
    public init() {}
    
    /// Probes a given media file URL using `ffprobe` and returns a deserialized `MediaFile` model.
    public func probe(fileURL: URL) async throws -> MediaFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ProbeError.fileNotFound(fileURL)
        }
        
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw ProbeError.permissionDenied(fileURL)
        }
        
        let ext = fileURL.pathExtension.lowercased()
        if Self.unsupportedImageExtensions.contains(ext) {
            throw ProbeError.unsupportedImage(extension: fileURL.pathExtension.uppercased())
        }
        
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? UInt64, size == 0 {
            throw ProbeError.emptyFile(fileURL.lastPathComponent)
        }
        
        guard let ffprobePath = FFmpegLocator.shared.ffprobePath else {
            throw ProbeError.ffprobeNotFound
        }
        
        let arguments = [
            "-v", "error",
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
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        let (terminationStream, terminationContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { terminatedProcess in
            terminatedProcess.terminationHandler = nil
            terminationContinuation.yield(terminatedProcess.terminationStatus)
            terminationContinuation.finish()
        }
        
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            terminationContinuation.finish()
            throw ProbeError.executionFailed(error.localizedDescription)
        }
        
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        var exitStatus: Int32?
        for await status in terminationStream {
            exitStatus = status
            break
        }
        process.terminationHandler = nil
        let finalStatus = exitStatus ?? (process.isRunning ? -1 : process.terminationStatus)
        
        if finalStatus != 0 {
            let rawStderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let ext = fileURL.pathExtension.lowercased()
            
            // Check if extension is not recognized as a media format
            if !Self.commonMediaExtensions.contains(ext) {
                throw ProbeError.unsupportedFormat(extension: fileURL.pathExtension.uppercased())
            }
            
            if rawStderr.localizedCaseInsensitiveContains("Invalid data found when processing input") {
                throw ProbeError.corruptedMedia("The media file structure is invalid or corrupt.")
            } else if rawStderr.localizedCaseInsensitiveContains("moov atom not found") {
                throw ProbeError.corruptedMedia("Missing index header (moov atom not found). The file may be incomplete or still downloading.")
            } else if rawStderr.localizedCaseInsensitiveContains("EBML") || rawStderr.localizedCaseInsensitiveContains("header") {
                throw ProbeError.corruptedMedia("Damaged or truncated container header.")
            } else if rawStderr.localizedCaseInsensitiveContains("Permission denied") {
                throw ProbeError.permissionDenied(fileURL)
            } else if rawStderr.localizedCaseInsensitiveContains("No such file") {
                throw ProbeError.fileNotFound(fileURL)
            } else if rawStderr.isEmpty {
                throw ProbeError.corruptedMedia("Unable to read media streams.")
            } else {
                var cleaned = rawStderr
                if let colonRange = cleaned.range(of: ": ") {
                    cleaned = String(cleaned[colonRange.upperBound...])
                }
                throw ProbeError.corruptedMedia(cleaned)
            }
        }
        
        let probeResult: FFprobeOutput
        do {
            probeResult = try Self.jsonDecoder.decode(FFprobeOutput.self, from: data)
        } catch {
            throw ProbeError.decodingFailed(error.localizedDescription)
        }
        
        let formatName = probeResult.format?.format_name?.lowercased() ?? ""
        let isImageDemuxer = formatName.contains("image2") || formatName.contains("png_pipe") || formatName.contains("jpeg_pipe") || formatName.contains("bmp_pipe") || formatName.contains("tiff_pipe")
        let hasNoAudio = (probeResult.streams?.filter { $0.codec_type == "audio" }.isEmpty) ?? true
        if (isImageDemuxer && hasNoAudio) || Self.unsupportedImageExtensions.contains(ext) {
            throw ProbeError.unsupportedImage(extension: fileURL.pathExtension.uppercased())
        }
        
        let mediaFile = buildMediaFile(from: probeResult, fileURL: fileURL)
        if mediaFile.tracks.isEmpty {
            throw ProbeError.noStreamsFound(fileURL.lastPathComponent)
        }
        return mediaFile
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
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw ProbeError.permissionDenied(fileURL)
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
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice
            
            let (terminationStream, terminationContinuation) = AsyncStream<Int32>.makeStream()
            process.terminationHandler = { terminatedProcess in
                terminatedProcess.terminationHandler = nil
                terminationContinuation.yield(terminatedProcess.terminationStatus)
                terminationContinuation.finish()
            }
            
            if (try? process.run()) != nil {
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                for await _ in terminationStream { break }
                process.terminationHandler = nil
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
        let startTime = Double(fmt?.start_time ?? "0") ?? 0.0
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
                let dispFlags = Self.parseDispositionFlags(stream.disposition)
                
                let fpsString = formatFrameRate(stream.avg_frame_rate) ?? formatFrameRate(stream.r_frame_rate)
                let rFpsString = formatFrameRate(stream.r_frame_rate)
                
                let cleanTag: String? = {
                    guard let tag = stream.codec_tag_string,
                          !tag.isEmpty,
                          tag != "[0][0][0][0]",
                          tag != "0x0000" else { return nil }
                    return tag
                }()
                
                let parsedBitDepth: Int? = Self.resolveBitDepth(
                    rawBitsPerSample: stream.bits_per_raw_sample,
                    audioBitsPerSample: stream.bits_per_sample,
                    pixFmt: stream.pix_fmt,
                    sampleFmt: stream.sample_fmt,
                    mediaType: mType
                )
                
                let isDoVi = stream.side_data_list?.contains { sd in
                    let t = sd.side_data_type?.lowercased() ?? ""
                    return t.contains("dovi") || t.contains("dolby vision")
                } ?? false
                
                let track = MediaTrack(
                    streamIndex: stream.index,
                    mediaType: mType,
                    codecName: codecName,
                    codecLongName: stream.codec_long_name,
                    profile: stream.profile,
                    codecTag: cleanTag,
                    codecLevel: stream.level,
                    width: stream.width,
                    height: stream.height,
                    frameRate: fpsString,
                    rFrameRate: rFpsString,
                    pixelFormat: stream.pix_fmt,
                    colorSpace: stream.color_space,
                    colorPrimaries: stream.color_primaries,
                    colorTransfer: stream.color_transfer,
                    colorRange: stream.color_range,
                    chromaLocation: stream.chroma_location,
                    fieldOrder: stream.field_order,
                    sampleAspectRatio: (stream.sample_aspect_ratio == "0:1") ? nil : stream.sample_aspect_ratio,
                    displayAspectRatio: (stream.display_aspect_ratio == "0:1") ? nil : stream.display_aspect_ratio,
                    bitDepth: parsedBitDepth,
                    hasBFrames: stream.has_b_frames,
                    frameCount: stream.nb_frames.flatMap { Int($0) },
                    isHDRDolbyVision: isDoVi,
                    channels: stream.channels,
                    channelLayout: stream.channel_layout,
                    sampleRate: stream.sample_rate,
                    sampleFormat: stream.sample_fmt,
                    bitRate: Int64(stream.bit_rate ?? "0"),
                    language: lang,
                    title: title,
                    isDefault: isDef,
                    isForced: isFrc,
                    dispositionFlags: dispFlags,
                    tags: stream.tags ?? [:],
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
            startTime: startTime,
            overallBitRate: bitRate,
            tags: tags,
            tracks: tracks,
            chapters: chapters
        )
    }
    
    private static func resolveBitDepth(
        rawBitsPerSample: String?,
        audioBitsPerSample: Int?,
        pixFmt: String?,
        sampleFmt: String?,
        mediaType: MediaType
    ) -> Int? {
        if let raw = rawBitsPerSample, let val = Int(raw), val > 0 {
            return val
        }
        if mediaType == .audio {
            if let abps = audioBitsPerSample, abps > 0 {
                return abps
            }
            let sf = sampleFmt?.lowercased() ?? ""
            if sf.contains("16") { return 16 }
            if sf.contains("24") { return 24 }
            if sf.contains("32") || sf.contains("flt") { return 32 }
            if sf.contains("64") || sf.contains("dbl") { return 64 }
            if sf.contains("8") { return 8 }
        } else if mediaType == .video {
            let pf = pixFmt?.lowercased() ?? ""
            if pf.contains("12") { return 12 }
            if pf.contains("10") || pf.contains("p010") || pf.contains("p210") || pf.contains("p410") { return 10 }
            if !pf.isEmpty { return 8 }
        }
        return nil
    }
    
    private static func parseDispositionFlags(_ raw: [String: Int]?) -> [String] {
        guard let raw else { return [] }
        let order: [(key: String, label: String)] = [
            ("default", "Default"),
            ("forced", "Forced"),
            ("original", "Original"),
            ("dub", "Dub"),
            ("comment", "Commentary"),
            ("hearing_impaired", "SDH / Hearing Impaired"),
            ("visual_impaired", "Audio Description"),
            ("captions", "Captions"),
            ("descriptions", "Descriptions"),
            ("lyrics", "Lyrics"),
            ("karaoke", "Karaoke"),
            ("attached_pic", "Attached Cover Art")
        ]
        var result: [String] = []
        for entry in order where (raw[entry.key] ?? 0) != 0 {
            result.append(entry.label)
        }
        return result
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
