import Testing
import Foundation
@testable import StrataCore

@Suite("StrataCore Engine & Model Tests")
struct StrataCoreTests {
    
    @Test("Duration and Time Parsing Formatter")
    func testTimeFormatters() {
        #expect(MediaFormatters.formatDuration(0) == "00:00")
        #expect(MediaFormatters.formatDuration(75) == "01:15")
        #expect(MediaFormatters.formatDuration(3665) == "01:01:05")
        
        #expect(MediaFormatters.parseTimeString("01:15") == 75.0)
        #expect(MediaFormatters.parseTimeString("01:01:05") == 3665.0)
        #expect(MediaFormatters.parseTimeString("25.5") == 25.5)
    }
    
    @Test("FFmpeg stderr Progress Line Parsing")
    func testFFmpegProgressParsing() {
        let sampleStderr = "frame=  240 fps= 60.0 q=-1.0 size=    1024kB time=00:00:10.00 bitrate= 838.9kbits/s speed=2.50x"
        let update = MediaFormatters.parseFFmpegProgress(line: sampleStderr, totalDuration: 20.0)
        
        #expect(update != nil)
        #expect(update?.currentTime == 10.0)
        #expect(update?.totalTime == 20.0)
        #expect(update?.progress == 0.5)
        #expect(update?.fps == 60.0)
        #expect(update?.speed == "2.50x")
    }
    
    @Test("Remux Engine Command Builder with Passthrough and Metadata Stripping")
    func testRemuxCommandBuilder() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/test_video.mkv")
        let outputURL = URL(fileURLWithPath: "/tmp/test_video.mp4")
        
        let videoTrack = MediaTrack(
            streamIndex: 0,
            mediaType: .video,
            codecName: "h264",
            isSelected: true,
            action: .copy
        )
        
        let audioTrack = MediaTrack(
            streamIndex: 1,
            mediaType: .audio,
            codecName: "aac",
            language: "eng",
            title: "Stereo Audio",
            isSelected: true,
            action: .copy
        )
        
        let mediaFile = MediaFile(
            url: sourceURL,
            filename: "test_video.mkv",
            fileSize: 1024 * 1024 * 50,
            containerFormat: "matroska",
            duration: 120.0,
            tracks: [videoTrack, audioTrack]
        )
        
        let options = RemuxOptions(
            targetContainer: .mp4,
            outputURL: outputURL,
            stripAllMetadata: true,
            stripChapters: false,
            fastStart: true
        )
        
        let args = try RemuxEngine.buildArguments(for: mediaFile, options: options)
        
        // Assert inputs
        #expect(args.contains("-i"))
        #expect(args.contains(sourceURL.path))
        
        // Assert stream mappings
        #expect(args.contains("-map"))
        #expect(args.contains("0:0"))
        #expect(args.contains("0:1"))
        
        // Assert codecs
        #expect(args.contains("-c:v:0"))
        #expect(args.contains("-c:a:0"))
        #expect(args.contains("copy"))
        
        // Assert metadata stripping
        #expect(args.contains("-map_metadata"))
        #expect(args.contains("-1"))
        
        // Assert faststart
        #expect(args.contains("-movflags"))
        #expect(args.contains("+faststart"))
        
        // Assert output file
        #expect(args.last == outputURL.path)
    }
    
    @Test("Remux Engine Command Builder with External Subtitles and Audio Transcoding")
    func testExternalSubtitleCommandBuilder() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/sample.mp4")
        let subURL = URL(fileURLWithPath: "/tmp/sample_sub.srt")
        let outputURL = URL(fileURLWithPath: "/tmp/sample_remuxed.mkv")
        
        let videoTrack = MediaTrack(
            streamIndex: 0,
            mediaType: .video,
            codecName: "hevc",
            isSelected: true,
            action: .copy
        )
        
        let audioTrack = MediaTrack(
            streamIndex: 1,
            mediaType: .audio,
            codecName: "dts",
            isSelected: true,
            action: .transcodeAC3_51
        )
        
        let subTrack = MediaTrack(
            streamIndex: 0,
            mediaType: .subtitle,
            codecName: "subrip",
            language: "fra",
            title: "French Subtitles",
            isSelected: true,
            action: .copy,
            isExternal: true,
            externalURL: subURL
        )
        
        let mediaFile = MediaFile(
            url: sourceURL,
            filename: "sample.mp4",
            fileSize: 100_000_000,
            containerFormat: "mov,mp4",
            duration: 300.0,
            tracks: [videoTrack, audioTrack, subTrack]
        )
        
        let options = RemuxOptions(
            targetContainer: .mkv,
            outputURL: outputURL,
            stripAllMetadata: false,
            stripChapters: false,
            fastStart: false
        )
        
        let args = try RemuxEngine.buildArguments(for: mediaFile, options: options)
        
        #expect(args.contains(sourceURL.path))
        #expect(args.contains(subURL.path))
        #expect(args.contains("1:0"))
        #expect(args.contains("ac3"))
    }
    
    @Test("Audio Transcoding: ALAC, FLAC and Bit Depth Command Building")
    func testALACAndFLACEncoding() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mkv")
        let outputURL = URL(fileURLWithPath: "/tmp/output.m4a")
        
        var alacTrack24 = MediaTrack(
            streamIndex: 0,
            mediaType: .audio,
            codecName: "flac",
            isSelected: true,
            action: .transcodeALAC
        )
        alacTrack24.audioConfig = AudioEncodingConfig(bitDepth: "24")
        
        let file24 = MediaFile(
            url: sourceURL,
            filename: "source.mkv",
            fileSize: 50_000_000,
            containerFormat: "matroska",
            duration: 60.0,
            tracks: [alacTrack24]
        )
        
        let options = RemuxOptions(targetContainer: .m4v, outputURL: outputURL)
        let args24 = try RemuxEngine.buildArguments(for: file24, options: options)
        #expect(args24.contains("alac"))
        #expect(args24.contains("s32p"))
        
        var alacTrack16 = alacTrack24
        alacTrack16.audioConfig = AudioEncodingConfig(bitDepth: "16")
        let file16 = MediaFile(
            url: sourceURL,
            filename: "source.mkv",
            fileSize: 50_000_000,
            containerFormat: "matroska",
            duration: 60.0,
            tracks: [alacTrack16]
        )
        let args16 = try RemuxEngine.buildArguments(for: file16, options: options)
        #expect(args16.contains("s16p"))
        
        var flacTrack24 = alacTrack24
        flacTrack24.action = .transcodeFLAC
        flacTrack24.audioConfig = AudioEncodingConfig(bitDepth: "24")
        let fileFLAC24 = MediaFile(
            url: sourceURL,
            filename: "source.mkv",
            fileSize: 50_000_000,
            containerFormat: "matroska",
            duration: 60.0,
            tracks: [flacTrack24]
        )
        let argsFLAC24 = try RemuxEngine.buildArguments(for: fileFLAC24, options: options)
        #expect(argsFLAC24.contains("flac"))
        #expect(argsFLAC24.contains("s32"))
    }
    
    @Test("Audio Transcoding: WAV and AIFF PCM Bit Depth and Rate Command Building")
    func testWAVAndAIFFAudioTranscoding() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mkv")
        let outputURL = URL(fileURLWithPath: "/tmp/output.mkv")
        let options = RemuxOptions(targetContainer: .mkv, outputURL: outputURL)
        
        var wavTrack = MediaTrack(streamIndex: 0, mediaType: .audio, codecName: "flac", isSelected: true)
        wavTrack.action = .transcodeWAV
        wavTrack.audioConfig = AudioEncodingConfig(sampleRate: "96000", channels: 2, bitDepth: "24")
        
        let wavFile = MediaFile(
            url: sourceURL,
            filename: "source.mkv",
            fileSize: 10_000_000,
            containerFormat: "matroska",
            duration: 60.0,
            tracks: [wavTrack]
        )
        let wavArgs = try RemuxEngine.buildArguments(for: wavFile, options: options)
        #expect(wavArgs.contains("pcm_s24le"))
        #expect(wavArgs.contains("96000"))
        #expect(wavArgs.contains("2"))
        
        var wavFloatTrack = wavTrack
        wavFloatTrack.audioConfig.bitDepth = "32float"
        let wavFloatFile = MediaFile(
            url: sourceURL,
            filename: "source.mkv",
            fileSize: 10_000_000,
            containerFormat: "matroska",
            duration: 60.0,
            tracks: [wavFloatTrack]
        )
        let wavFloatArgs = try RemuxEngine.buildArguments(for: wavFloatFile, options: options)
        #expect(wavFloatArgs.contains("pcm_f32le"))
        
        var aiffTrack = MediaTrack(streamIndex: 0, mediaType: .audio, codecName: "alac", isSelected: true)
        aiffTrack.action = .transcodeAIFF
        aiffTrack.audioConfig = AudioEncodingConfig(sampleRate: "48000", channels: 6, bitDepth: "24")
        
        let aiffFile = MediaFile(
            url: sourceURL,
            filename: "source.mkv",
            fileSize: 10_000_000,
            containerFormat: "matroska",
            duration: 60.0,
            tracks: [aiffTrack]
        )
        let aiffArgs = try RemuxEngine.buildArguments(for: aiffFile, options: options)
        #expect(aiffArgs.contains("pcm_s24be"))
        #expect(aiffArgs.contains("48000"))
        #expect(aiffArgs.contains("6"))
        
        #expect(wavTrack.exportExtension == "wav")
        #expect(aiffTrack.exportExtension == "aiff")
        
        let videoTrackH264 = MediaTrack(streamIndex: 0, mediaType: .video, codecName: "h264", isSelected: true)
        let videoTrackProRes = MediaTrack(streamIndex: 0, mediaType: .video, codecName: "prores", isSelected: true)
        let videoTrackHEVC = MediaTrack(streamIndex: 0, mediaType: .video, codecName: "hevc", isSelected: true)
        let videoTrackVP9 = MediaTrack(streamIndex: 0, mediaType: .video, codecName: "vp9", isSelected: true)
        #expect(videoTrackH264.exportExtension == "mp4")
        #expect(videoTrackProRes.exportExtension == "mov")
        #expect(videoTrackHEVC.exportExtension == "mp4")
        #expect(videoTrackVP9.exportExtension == "webm")
    }
    
    @Test("Extraction Filename Pattern Formatting")
    func testExtractionFilenamePattern() {
        let track = MediaTrack(
            streamIndex: 2,
            mediaType: .audio,
            codecName: "mp3",
            channels: 2,
            language: "eng",
            title: "Director Commentary",
            action: .transcodeMP3
        )
        
        let pattern1 = "{filename}.{title}.{ext}"
        let name1 = NamingPatternHelper.formatFilename(pattern: pattern1, sourceFilename: "Matrix.mkv", track: track, targetExtension: "mp3")
        #expect(name1 == "Matrix.Director Commentary.mp3")
        
        let pattern2 = "{filename}_track{index}_{lang}.{ext}"
        let name2 = NamingPatternHelper.formatFilename(pattern: pattern2, sourceFilename: "Matrix.mkv", track: track, targetExtension: "mp3")
        #expect(name2 == "Matrix_track2_eng.mp3")
    }
    
    @Test("Remux Engine Multiple External Input Sources Mapping")
    func testMultipleExternalInputsCommandBuilder() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/movie.mkv")
        let extAudioURL = URL(fileURLWithPath: "/tmp/commentary.m4a")
        let extSubURL = URL(fileURLWithPath: "/tmp/subtitles.srt")
        let outputURL = URL(fileURLWithPath: "/tmp/movie_muxed.mkv")
        
        let primaryVideo = MediaTrack(streamIndex: 0, mediaType: .video, codecName: "h264", isSelected: true)
        let primaryAudio = MediaTrack(streamIndex: 1, mediaType: .audio, codecName: "aac", isSelected: true)
        let extAudio = MediaTrack(
            streamIndex: 0,
            mediaType: .audio,
            codecName: "aac",
            title: "Commentary",
            isSelected: true,
            isExternal: true,
            externalURL: extAudioURL
        )
        let extSub = MediaTrack(
            streamIndex: 0,
            mediaType: .subtitle,
            codecName: "subrip",
            title: "English",
            isSelected: true,
            isExternal: true,
            externalURL: extSubURL
        )
        
        let file = MediaFile(
            url: sourceURL,
            filename: "movie.mkv",
            fileSize: 200_000_000,
            containerFormat: "matroska",
            duration: 3600.0,
            tracks: [primaryVideo, primaryAudio, extAudio, extSub]
        )
        
        let options = RemuxOptions(targetContainer: .mkv, outputURL: outputURL)
        let args = try RemuxEngine.buildArguments(for: file, options: options)
        
        #expect(args.contains(sourceURL.path))
        #expect(args.contains(extAudioURL.path))
        #expect(args.contains(extSubURL.path))
        
        #expect(args.contains("0:0"))
        #expect(args.contains("0:1"))
        #expect(args.contains("1:0"))
        #expect(args.contains("2:0"))
    }
    
    @Test("Probe Error Diagnostic Descriptions")
    func testProbeErrorDescriptions() {
        let unsupported = ProbeError.unsupportedFormat(extension: "PDF")
        #expect(unsupported.errorDescription?.contains("Unsupported File Format: '.PDF' is not a supported media file") == true)
        
        let unsupportedImg = ProbeError.unsupportedImage(extension: "PNG")
        #expect(unsupportedImg.errorDescription?.contains("Unsupported Image Format: '.PNG' is a static image") == true)
        
        #expect(ProbePipeline.unsupportedImageExtensions.contains("png"))
        #expect(ProbePipeline.unsupportedImageExtensions.contains("jpg"))
        #expect(ProbePipeline.unsupportedImageExtensions.contains("heic"))
        #expect(ProbePipeline.unsupportedImageExtensions.contains("webp"))
        #expect(!ProbePipeline.unsupportedImageExtensions.contains("gif"))
        #expect(ProbePipeline.commonMediaExtensions.contains("gif"))
        
        let empty = ProbeError.emptyFile("blank.mp4")
        #expect(empty.errorDescription == "Empty File: 'blank.mp4' contains no data (0 bytes).")
        
        let noStreams = ProbeError.noStreamsFound("dummy.mkv")
        #expect(noStreams.errorDescription == "No Media Streams: No playable audio, video, or subtitle tracks were found in 'dummy.mkv'.")
        
        let missing = ProbeError.fileNotFound(URL(fileURLWithPath: "/tmp/nonexistent.mkv"))
        #expect(missing.errorDescription?.contains("File Not Found: 'nonexistent.mkv'") == true)
        
        let corrupt = ProbeError.corruptedMedia("Missing index header (moov atom not found).")
        #expect(corrupt.errorDescription == "Corrupted Media: Missing index header (moov atom not found).")
        
        // Assert no error contains the legacy unhelpful string "ffprobe execution failed:"
        let legacyExec = ProbeError.executionFailed("Exit code 1")
        #expect(legacyExec.errorDescription?.contains("ffprobe execution failed:") == false)
    }
    
    @Test("Video Transcoding: TrackAction Titles, VideoEncodingConfig Defaults, Sanitization, and Command Construction")
    func testVideoEncodingConfigAndCommandBuilder() throws {
        // 1. Clean UI Titles (no "VideoToolbox" noise)
        #expect(TrackAction.transcodeH264_VT.title == "H.264")
        #expect(TrackAction.transcodeHEVC_VT.title == "HEVC / H.265")
        #expect(TrackAction.transcodeProRes.title == "Apple ProRes")
        #expect(TrackAction.transcodeH264_VT.supportsVideoConfig == true)
        #expect(TrackAction.transcodeHEVC_VT.supportsVideoConfig == true)
        #expect(TrackAction.transcodeProRes.supportsVideoConfig == true)
        #expect(TrackAction.copy.supportsVideoConfig == false)
        
        // 2. Defaults ("auto" for H.264/HEVC click-and-go; "2" Standard for ProRes) & Sanitization
        var config = VideoEncodingConfig.default(for: .transcodeH264_VT)
        #expect(config.profile == "auto")
        #expect(config.entropyMode == .auto)
        #expect(config.fieldOrder == nil)
        #expect(config.allowFrameReordering == true)
        #expect(config.preserveAlpha == false)
        config.frameRate = "24"
        config.colorSpace = .rec709
        config.profile = "baseline"
        config.entropyMode = .cabac
        config.sanitize(for: .transcodeH264_VT)
        #expect(config.entropyMode == .cavlc)
        
        // Switching to HEVC preserves frameRate & colorSpace while resetting to HEVC defaults
        config.sanitize(for: .transcodeHEVC_VT)
        #expect(config.profile == "auto")
        #expect(config.entropyMode == nil)
        #expect(config.frameRate == "24")
        #expect(config.colorSpace == .rec709)
        
        // HEVC alpha disabled for 10-bit or multi-pass or 4:2:2
        config.profile = "main"
        config.preserveAlpha = true
        config.sanitize(for: .transcodeHEVC_VT)
        #expect(config.preserveAlpha == true)
        config.profile = "main422"
        config.sanitize(for: .transcodeHEVC_VT)
        #expect(config.preserveAlpha == false)
        
        // Switching to ProRes sets Standard (2) and resets bitrate/multipass/keyFrameInterval
        config.bitrate = "15000k"
        config.keyFrameInterval = 48
        config.multiPass = true
        config.fieldOrder = .topFirst
        config.sanitize(for: .transcodeProRes)
        #expect(config.profile == "2")
        #expect(config.bitrate == "auto")
        #expect(config.keyFrameInterval == nil)
        #expect(config.multiPass == false)
        #expect(config.preserveAlpha == false)
        
        // Switching from ProRes Top First to HEVC clears incompatible interlaced fieldOrder
        config.sanitize(for: .transcodeHEVC_VT)
        #expect(config.fieldOrder == nil)
        
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mkv")
        let mp4Out = URL(fileURLWithPath: "/tmp/out.mp4")
        let movOut = URL(fileURLWithPath: "/tmp/out.mov")
        
        // 3. H.264 Hardware Single-Pass Command Construction (Frame Reordering ON vs OFF)
        let h264Track = MediaTrack(
            streamIndex: 0,
            mediaType: .video,
            codecName: "h264",
            width: 1920,
            height: 1080,
            isSelected: true,
            action: .transcodeH264_VT,
            videoConfig: VideoEncodingConfig(
                bitrate: "15000k",
                frameRate: "24000/1001",
                colorSpace: .rec709,
                profile: "high",
                entropyMode: .cabac,
                keyFrameInterval: 48,
                allowFrameReordering: true,
                multiPass: false
            )
        )
        let h264Args = try RemuxEngine.buildArguments(
            for: MediaFile(url: sourceURL, filename: "source.mkv", fileSize: 10_000, containerFormat: "matroska", duration: 10, tracks: [h264Track]),
            options: RemuxOptions(targetContainer: .mp4, outputURL: mp4Out)
        )
        #expect(h264Args.contains("h264_videotoolbox"))
        #expect(h264Args.contains("-profile:v:0"))
        #expect(h264Args.contains("high"))
        #expect(h264Args.contains("-coder:v:0"))
        #expect(h264Args.contains("cabac"))
        #expect(h264Args.contains("-bf:v:0"))
        #expect(h264Args.contains("2"))
        #expect(h264Args.contains("-b:v:0"))
        #expect(h264Args.contains("15000k"))
        #expect(h264Args.contains("-g:v:0"))
        #expect(h264Args.contains("48"))
        #expect(h264Args.contains("-r:v:0"))
        #expect(h264Args.contains("24000/1001"))
        #expect(h264Args.contains("-color_primaries:v:0"))
        #expect(h264Args.contains("bt709"))
        #expect(h264Args.contains { $0.contains("yadif=0:-1:1,setparams=field_mode=prog:color_primaries=bt709") })
        
        // 4. HEVC 10-bit 4:2:0, HEVC 8-bit 4:2:2 (x265), & HEVC Alpha (bgra)
        let hevc10Track = MediaTrack(
            streamIndex: 0,
            mediaType: .video,
            codecName: "h264",
            pixelFormat: "yuv420p",
            isSelected: true,
            action: .transcodeHEVC_VT,
            videoConfig: VideoEncodingConfig(
                bitrate: "auto",
                frameRate: "30",
                colorSpace: .rec2020HLG,
                profile: "main10",
                keyFrameInterval: 60,
                allowFrameReordering: false,
                multiPass: false
            )
        )
        let hevcArgs = try RemuxEngine.buildArguments(
            for: MediaFile(url: sourceURL, filename: "source.mkv", fileSize: 10_000, containerFormat: "matroska", duration: 10, tracks: [hevc10Track]),
            options: RemuxOptions(targetContainer: .mp4, outputURL: mp4Out)
        )
        #expect(hevcArgs.contains("hevc_videotoolbox"))
        #expect(hevcArgs.contains("main10"))
        #expect(hevcArgs.contains("p010le"))
        #expect(hevcArgs.contains("hvc1"))
        #expect(hevcArgs.contains("arib-std-b67"))
        #expect(hevcArgs.contains("-bf:v:0"))
        #expect(hevcArgs.contains("0"))
        #expect(!hevcArgs.contains("-b:v:0"))
        
        let hevc422_8Track = MediaTrack(
            streamIndex: 0,
            mediaType: .video,
            codecName: "h264",
            pixelFormat: "yuv420p",
            isSelected: true,
            action: .transcodeHEVC_VT,
            videoConfig: VideoEncodingConfig(profile: "main422", allowFrameReordering: false)
        )
        let hevc422_8Args = try RemuxEngine.buildArguments(
            for: MediaFile(url: sourceURL, filename: "source.mkv", fileSize: 10_000, containerFormat: "matroska", duration: 10, tracks: [hevc422_8Track]),
            options: RemuxOptions(targetContainer: .mp4, outputURL: mp4Out)
        )
        #expect(hevc422_8Args.contains("libx265"))
        #expect(hevc422_8Args.contains("yuv422p"))
        #expect(!hevc422_8Args.contains("-profile:v:0"))
        
        let hevcAlphaTrack = MediaTrack(
            streamIndex: 0,
            mediaType: .video,
            codecName: "prores",
            pixelFormat: "yuva444p10le",
            isSelected: true,
            action: .transcodeHEVC_VT,
            videoConfig: VideoEncodingConfig(profile: "auto", preserveAlpha: true)
        )
        let hevcAlphaArgs = try RemuxEngine.buildArguments(
            for: MediaFile(url: sourceURL, filename: "source.mkv", fileSize: 10_000, containerFormat: "matroska", duration: 10, tracks: [hevcAlphaTrack]),
            options: RemuxOptions(targetContainer: .mov, outputURL: movOut)
        )
        #expect(hevcAlphaArgs.contains("bgra"))
        #expect(hevcAlphaArgs.contains("-alpha_quality:v:0"))
        
        // 5. Hardware-Accelerated Video Decoding (-hwaccel videotoolbox) & ProRes 4444/422 Hardware Encoding
        let proResAlphaKeep = MediaTrack(
            streamIndex: 0,
            mediaType: .video,
            codecName: "prores",
            pixelFormat: "yuva444p10le",
            isSelected: true,
            action: .transcodeProRes,
            videoConfig: VideoEncodingConfig(frameRate: "25", fieldOrder: .topFirst, colorSpace: .rec709, profile: "4", preserveAlpha: true)
        )
        let proResKeepArgs = try RemuxEngine.buildArguments(
            for: MediaFile(url: sourceURL, filename: "source.mkv", fileSize: 10_000, containerFormat: "matroska", duration: 10, tracks: [proResAlphaKeep]),
            options: RemuxOptions(targetContainer: .mov, outputURL: movOut)
        )
        #expect(proResKeepArgs.prefix(5) == ["-y", "-hide_banner", "-hwaccel", "videotoolbox", "-i"])
        #expect(proResKeepArgs.contains("prores_videotoolbox"))
        #expect(proResKeepArgs.contains("-allow_sw:v:0"))
        #expect(proResKeepArgs.contains("ayuv64le"))
        #expect(proResKeepArgs.contains("+ilme+ildct"))
        #expect(proResKeepArgs.contains("tt"))
        #expect(proResKeepArgs.contains { $0.contains("field_mode=tff") })
        
        var proResStripAlpha = proResAlphaKeep
        proResStripAlpha.videoConfig.preserveAlpha = false
        proResStripAlpha.videoConfig.fieldOrder = .progressive
        let proResStripArgs = try RemuxEngine.buildArguments(
            for: MediaFile(url: sourceURL, filename: "source.mkv", fileSize: 10_000, containerFormat: "matroska", duration: 10, tracks: [proResStripAlpha]),
            options: RemuxOptions(targetContainer: .mov, outputURL: movOut)
        )
        #expect(proResStripArgs.contains("prores_videotoolbox"))
        #expect(proResStripArgs.contains("p410le"))
        #expect(proResStripArgs.contains("progressive"))
        #expect(proResStripArgs.contains { $0.contains("yadif=0:-1:1,setparams=field_mode=prog") })
        
        var proRes422HQ = proResAlphaKeep
        proRes422HQ.videoConfig.profile = "3"
        proRes422HQ.videoConfig.preserveAlpha = true
        let proRes422Args = try RemuxEngine.buildArguments(
            for: MediaFile(url: sourceURL, filename: "source.mkv", fileSize: 10_000, containerFormat: "matroska", duration: 10, tracks: [proRes422HQ]),
            options: RemuxOptions(targetContainer: .mov, outputURL: movOut)
        )
        #expect(proRes422Args.contains("prores_videotoolbox"))
        #expect(proRes422Args.contains("p210le"))
        
        // Software fallback when useHardwareAcceleration == false
        let proResSWArgs = try RemuxEngine.buildArguments(
            for: MediaFile(url: sourceURL, filename: "source.mkv", fileSize: 10_000, containerFormat: "matroska", duration: 10, tracks: [proResAlphaKeep]),
            options: RemuxOptions(targetContainer: .mov, outputURL: movOut, useHardwareAcceleration: false)
        )
        #expect(!proResSWArgs.contains("-hwaccel"))
        #expect(proResSWArgs.contains("prores_ks"))
        #expect(proResSWArgs.contains("yuva444p10le"))
        
        // Passthrough video (even with audio transcode) omits -hwaccel videotoolbox
        let copyVideoTrack = MediaTrack(streamIndex: 0, mediaType: .video, codecName: "h264", isSelected: true, action: .copy)
        let transcodeAudioTrack = MediaTrack(streamIndex: 1, mediaType: .audio, codecName: "ac3", isSelected: true, action: .transcodeAAC_Stereo)
        let passthroughVideoArgs = try RemuxEngine.buildArguments(
            for: MediaFile(url: sourceURL, filename: "source.mkv", fileSize: 10_000, containerFormat: "matroska", duration: 10, tracks: [copyVideoTrack, transcodeAudioTrack]),
            options: RemuxOptions(targetContainer: .mp4, outputURL: mp4Out)
        )
        #expect(!passthroughVideoArgs.contains("-hwaccel"))
        
        // External video transcoding adds -hwaccel videotoolbox specifically before that external input
        let extVideoURL = URL(fileURLWithPath: "/tmp/ext_video.mov")
        let extSubURL = URL(fileURLWithPath: "/tmp/ext_sub.srt")
        let extTranscodeVideo = MediaTrack(
            streamIndex: 0,
            mediaType: .video,
            codecName: "prores",
            isSelected: true,
            action: .transcodeH264_VT,
            isExternal: true,
            externalURL: extVideoURL
        )
        let extSub = MediaTrack(
            streamIndex: 0,
            mediaType: .subtitle,
            codecName: "subrip",
            isSelected: true,
            action: .copy,
            isExternal: true,
            externalURL: extSubURL
        )
        let multiInputArgs = try RemuxEngine.buildArguments(
            for: MediaFile(url: sourceURL, filename: "source.mkv", fileSize: 10_000, containerFormat: "matroska", duration: 10, tracks: [transcodeAudioTrack, extTranscodeVideo, extSub]),
            options: RemuxOptions(targetContainer: .mp4, outputURL: mp4Out)
        )
        let hwAccelIndices = multiInputArgs.enumerated().compactMap { $0.element == "-hwaccel" ? $0.offset : nil }
        #expect(hwAccelIndices.count == 1)
        if let idx = hwAccelIndices.first {
            #expect(multiInputArgs[idx + 1] == "videotoolbox")
            #expect(multiInputArgs[idx + 2] == "-i")
            #expect(multiInputArgs[idx + 3] == extVideoURL.path)
        }
        
        // Extraction arguments use HW decode + prores_videotoolbox when transcoding, omit -hwaccel for copy
        let sourceMedia = MediaFile(url: sourceURL, filename: "source.mkv", fileSize: 10_000, containerFormat: "matroska", duration: 10, tracks: [proResAlphaKeep, copyVideoTrack])
        let extractProResArgs = RemuxEngine.buildTrackExtractionArguments(file: sourceMedia, track: proResAlphaKeep, outputURL: movOut)
        #expect(extractProResArgs.prefix(5) == ["-y", "-hide_banner", "-hwaccel", "videotoolbox", "-i"])
        #expect(extractProResArgs.contains("prores_videotoolbox"))
        let extractCopyArgs = RemuxEngine.buildTrackExtractionArguments(file: sourceMedia, track: copyVideoTrack, outputURL: mp4Out)
        #expect(!extractCopyArgs.contains("-hwaccel"))
        let extractSWArgs = RemuxEngine.buildTrackExtractionArguments(file: sourceMedia, track: proResAlphaKeep, outputURL: movOut, useHardwareAcceleration: false)
        #expect(!extractSWArgs.contains("-hwaccel"))
        #expect(extractSWArgs.contains("prores_ks"))
        
        // 6. Multi-Pass Command Construction (Pass 1 & Pass 2 for H.264 Interlaced & HEVC)
        var mpTrack = MediaTrack(
            streamIndex: 0,
            mediaType: .video,
            codecName: "h264",
            width: 1920,
            height: 1080,
            isSelected: true,
            action: .transcodeH264_VT,
            videoConfig: VideoEncodingConfig(bitrate: "auto", fieldOrder: .bottomFirst, profile: "high", entropyMode: .cabac, multiPass: true)
        )
        let logDir = URL(fileURLWithPath: "/tmp/strata_pass_unit")
        let pass1 = try RemuxEngine.buildArguments(
            for: MediaFile(url: sourceURL, filename: "source.mkv", fileSize: 10_000, containerFormat: "matroska", duration: 10, tracks: [mpTrack]),
            options: RemuxOptions(targetContainer: .mp4, outputURL: mp4Out),
            pass: 1,
            passLogBaseURL: logDir
        )
        #expect(pass1.contains("libx264"))
        #expect(pass1.contains("-pass:v:0"))
        #expect(pass1.contains("1"))
        #expect(pass1.contains("-b:v:0"))
        #expect(pass1.contains("8000k"))
        #expect(pass1.contains("bff=1"))
        #expect(pass1.contains("null"))
        
        mpTrack.action = .transcodeHEVC_VT
        mpTrack.videoConfig.profile = "main10"
        mpTrack.videoConfig.fieldOrder = nil
        let hevcPass2 = try RemuxEngine.buildArguments(
            for: MediaFile(url: sourceURL, filename: "source.mkv", fileSize: 10_000, containerFormat: "matroska", duration: 10, tracks: [mpTrack]),
            options: RemuxOptions(targetContainer: .mp4, outputURL: mp4Out),
            pass: 2,
            passLogBaseURL: logDir
        )
        #expect(hevcPass2.contains("libx265"))
        #expect(hevcPass2.contains("yuv420p10le"))
        #expect(hevcPass2.contains("6000k"))
        #expect(hevcPass2.contains("-tag:v:0"))
        #expect(hevcPass2.contains("hvc1"))
        #expect(hevcPass2.contains { $0.contains("pass=2:stats=") })
    }
    
    @Test("Extended Media Telemetry Formatting and Technical Summary Generation")
    func testExtendedTelemetryFormatting() {
        let hevcHDRVideo = MediaTrack(
            streamIndex: 0,
            mediaType: .video,
            codecName: "hevc",
            codecLongName: "H.265 / HEVC",
            profile: "Main 10",
            codecTag: "hvc1",
            codecLevel: 153,
            width: 3840,
            height: 2160,
            frameRate: "23.98 fps",
            rFrameRate: "23.98 fps",
            pixelFormat: "yuv420p10le",
            colorSpace: "bt2020nc",
            colorPrimaries: "bt2020",
            colorTransfer: "smpte2084",
            colorRange: "tv",
            chromaLocation: "topleft",
            fieldOrder: "progressive",
            sampleAspectRatio: "1:1",
            displayAspectRatio: "16:9",
            bitDepth: 10,
            hasBFrames: 2,
            frameCount: 144000,
            isHDRDolbyVision: false,
            bitRate: 18_500_000,
            dispositionFlags: ["Default"],
            tags: ["ENCODER": "x265 3.6", "timecode": "01:00:00:00"]
        )
        
        let proResAlphaVideo = MediaTrack(
            streamIndex: 0,
            mediaType: .video,
            codecName: "prores",
            profile: "4444 XQ",
            codecTag: "ap4x",
            pixelFormat: "yuva444p10le",
            fieldOrder: "tt",
            bitDepth: 10,
            isHDRDolbyVision: true
        )
        
        let audioTrack = MediaTrack(
            streamIndex: 1,
            mediaType: .audio,
            codecName: "aac",
            profile: "LC",
            channels: 6,
            channelLayout: "5.1(side)",
            sampleRate: "48000",
            sampleFormat: "fltp",
            bitRate: 384_000,
            language: "eng",
            isDefault: true,
            dispositionFlags: ["Default"]
        )
        
        #expect(hevcHDRVideo.dynamicRangeBadge == "HDR10 (PQ)")
        #expect(hevcHDRVideo.codecLevelDisplay == "5.1")
        #expect(hevcHDRVideo.chromaSubsamplingDisplay == "4:2:0")
        #expect(hevcHDRVideo.formattedFieldOrder == "Progressive")
        #expect(hevcHDRVideo.formattedColorSpec == "Rec. 2020 PQ / HDR10 (9-16-9)")
        #expect(hevcHDRVideo.formattedColorRange == "Limited (16–235)")
        #expect(hevcHDRVideo.encoderName == "x265 3.6")
        #expect(hevcHDRVideo.startTimecode == "01:00:00:00")
        #expect(hevcHDRVideo.isVariableFrameRate == false)
        
        #expect(proResAlphaVideo.dynamicRangeBadge == "Dolby Vision")
        #expect(proResAlphaVideo.hasAlphaChannel == true)
        #expect(proResAlphaVideo.chromaSubsamplingDisplay == "4:4:4 + Alpha")
        #expect(proResAlphaVideo.formattedFieldOrder == "Interlaced (Top First)")
        
        #expect(audioTrack.formattedSampleRateDisplay == "48 kHz")
        #expect(audioTrack.formattedSampleFormat == "32-bit Float")
        #expect(audioTrack.formattedBitRate == "384 kbps")
        
        let subtitleTrack = MediaTrack(
            streamIndex: 2,
            mediaType: .subtitle,
            codecName: "subrip",
            language: "eng",
            title: "English SDH",
            isForced: true,
            dispositionFlags: ["Default", "Forced"]
        )
        
        let media = MediaFile(
            url: URL(fileURLWithPath: "/tmp/Master_Feature.mov"),
            filename: "Master_Feature.mov",
            fileSize: 2_500_000_000,
            containerFormat: "mov,mp4,m4a,3gp,3g2,mj2",
            containerLongName: "QuickTime / MOV",
            duration: 3661.25,
            startTime: 0.125,
            overallBitRate: 19_200_000,
            tags: [
                "writing_application": "StrataMux 1.0",
                "creation_time": "2026-11-09T12:30:00Z",
                "title": "Master Feature"
            ],
            tracks: [hevcHDRVideo, audioTrack, subtitleTrack],
            chapters: [MediaChapter(id: 0, startTime: 0, endTime: 1200, title: "Act I")]
        )
        
        #expect(media.preciseDuration == "01:01:01.250")
        #expect(media.dynamicRangeLabel == "HDR10 (PQ)")
        #expect(media.writingApplication == "StrataMux 1.0")
        #expect(media.creationDateDisplay != nil)
        let summary = media.technicalSummaryText
        #expect(summary.contains("Container & File:"))
        #expect(summary.contains("Master_Feature.mov"))
        #expect(summary.contains("QuickTime / MOV"))
        #expect(summary.contains("Total Streams: 3"))
        #expect(summary.contains("Start Offset: 0.125 s"))
        #expect(summary.contains("3840 × 2160"))
        #expect(summary.contains("Aspect Ratio: 16:9 (Display) • 1:1 Square"))
        #expect(summary.contains("Frame Rate: 23.98 fps (CFR)"))
        #expect(summary.contains("Rec. 2020 PQ / HDR10"))
        #expect(summary.contains("Color Range: Limited (16–235)"))
        #expect(summary.contains("Pixel Format: 10-bit • 4:2:0 • yuv420p10le"))
        #expect(summary.contains("Chroma Loc.: Topleft"))
        #expect(summary.contains("B-Frames: 2 reorder"))
        #expect(summary.contains("Frame Count: 144,000"))
        #expect(summary.contains("Stream Bit Rate: 18.5 Mbps"))
        #expect(summary.contains("Timecode: 01:00:00:00"))
        #expect(summary.contains("Flags: Default"))
        #expect(summary.contains("Language: English"))
        #expect(summary.contains("Sample Format: 32-bit Float"))
        #expect(summary.contains("Title: English SDH"))
        #expect(summary.contains("Flags: Default, Forced"))
        #expect(summary.contains("Metadata Tags (3):"))
        #expect(summary.contains("title: Master Feature"))
        #expect(summary.contains("Chapters (1)"))
        #expect(summary.contains("Act I"))
    }
    
    @Test("FFmpegLocator Init Does Not Pump CFRunLoop During Version Query")
    @MainActor
    func testFFmpegLocatorInitDoesNotPumpRunLoop() throws {
        var observerTickCount = 0
        let runLoop = CFRunLoopGetCurrent()
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.allActivities.rawValue,
            true,
            0
        ) { _, _ in
            observerTickCount += 1
        }
        if let observer {
            CFRunLoopAddObserver(runLoop, observer, .defaultMode)
            CFRunLoopAddObserver(runLoop, observer, .commonModes)
        }
        defer {
            if let observer {
                CFRunLoopRemoveObserver(runLoop, observer, .defaultMode)
                CFRunLoopRemoveObserver(runLoop, observer, .commonModes)
                CFRunLoopObserverInvalidate(observer)
            }
        }
        
        let locator = FFmpegLocator()
        if locator.isReady {
            #expect(locator.ffmpegVersion?.isEmpty == false)
        }
        #expect(observerTickCount == 0, "FFmpegLocator.init() must not spin CFRunLoop (prevents dispatch_once re-entrancy)")
    }
}
