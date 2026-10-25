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
}
