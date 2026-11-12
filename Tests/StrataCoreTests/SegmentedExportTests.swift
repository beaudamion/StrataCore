import Testing
import Foundation
@testable import StrataCore

@Suite("Segmented Single-File Export Engine Tests")
struct SegmentedExportTests {
    
    // MARK: - Helpers
    
    private static func resolveBinaries() -> (ffmpeg: String, ffprobe: String)? {
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        let ffmpegCandidates = [
            "\(cwd)/Sources/Strata/Resources/bin/ffmpeg",
            "\(cwd)/../Strata/Sources/Strata/Resources/bin/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg"
        ]
        let ffprobeCandidates = [
            "\(cwd)/Sources/Strata/Resources/bin/ffprobe",
            "\(cwd)/../Strata/Sources/Strata/Resources/bin/ffprobe",
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe"
        ]
        guard let ffmpeg = ffmpegCandidates.first(where: { fm.isExecutableFile(atPath: $0) }),
              let ffprobe = ffprobeCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return (ffmpeg, ffprobe)
    }
    
    private static func runProcess(executable: String, arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (proc.terminationStatus, stdout, stderr)
    }
    
    private static func probeFrameCount(url: URL, ffprobePath: String) throws -> Int {
        let (status, stdout, _) = try runProcess(
            executable: ffprobePath,
            arguments: [
                "-v", "error",
                "-select_streams", "v:0",
                "-count_frames",
                "-show_entries", "stream=nb_read_frames",
                "-of", "csv=p=0",
                url.path
            ]
        )
        guard status == 0 else { return -1 }
        return Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }
    
    private static func makeSampleMediaFile(duration: Double = 120.0, action: TrackAction = .transcodeH264_VT) -> MediaFile {
        let video = MediaTrack(
            streamIndex: 0,
            mediaType: .video,
            codecName: "h264",
            width: 1920,
            height: 1080,
            frameRate: "24 fps",
            isSelected: true,
            action: action
        )
        let audio = MediaTrack(
            streamIndex: 1,
            mediaType: .audio,
            codecName: "aac",
            channels: 2,
            sampleRate: "48000",
            language: "eng",
            title: "Main Audio",
            isSelected: true,
            action: .copy
        )
        return MediaFile(
            url: URL(fileURLWithPath: "/tmp/sample.mp4"),
            filename: "sample.mp4",
            fileSize: 50_000_000,
            containerFormat: "mov,mp4,m4a,3gp,3g2,mj2",
            duration: duration,
            tracks: [video, audio],
            chapters: [MediaChapter(id: 0, startTime: 0, endTime: 60, title: "Part 1")]
        )
    }
    
    // MARK: - 1. Hardware Capabilities & Segmentation Decision Matrix
    
    @Test("Live Hardware Capabilities Detection on Host Machine")
    func testLiveHardwareCapabilities() {
        let caps = HardwareCapabilities.detect()
        #expect(!caps.chipName.isEmpty)
        #expect(caps.cpuCoreCount > 0)
        #if arch(arm64)
        #expect(caps.isAppleSilicon == true)
        #expect(caps.h264HEVCEngineCount >= 1)
        #endif
    }
    
    @Test("Fallback Engine Tier Heuristic Matches Apple Silicon Generations")
    func testFallbackChipTiers() {
        #expect(HardwareCapabilities.fallbackEngineCounts(chipName: "Apple M1", isAppleSilicon: true) == (1, 0))
        #expect(HardwareCapabilities.fallbackEngineCounts(chipName: "Apple M1 Pro", isAppleSilicon: true) == (1, 1))
        #expect(HardwareCapabilities.fallbackEngineCounts(chipName: "Apple M2", isAppleSilicon: true) == (1, 1))
        #expect(HardwareCapabilities.fallbackEngineCounts(chipName: "Apple M5 Max", isAppleSilicon: true) == (2, 2))
        #expect(HardwareCapabilities.fallbackEngineCounts(chipName: "Apple M3 Ultra", isAppleSilicon: true) == (4, 4))
        #expect(HardwareCapabilities.fallbackEngineCounts(chipName: "Intel Core i9", isAppleSilicon: false) == (0, 0))
    }
    
    @Test("Segmentation Decision Matrix Across Silicon Tiers, Busy Engines, and Exclusions")
    func testSegmentationDecisionMatrix() {
        let file = Self.makeSampleMediaFile(duration: 120.0, action: .transcodeH264_VT)
        let optionsAuto = RemuxOptions(targetContainer: .mp4, outputURL: URL(fileURLWithPath: "/tmp/out.mp4"), segmentedEncodingMode: .auto)
        
        // 1. M5 Max idle -> 2 segments, no fallback notice
        let maxIdle = HardwareMediaCapabilities(
            chipName: "Apple M5 Max", cpuCoreCount: 18, isAppleSilicon: true,
            h264HEVCEngineCount: 2, proResEngineCount: 2,
            activeAVEEnginesInUse: 0, activeProResEnginesInUse: 0
        )
        let dMaxIdle = HardwareCapabilities.resolveSegmentation(for: file, options: optionsAuto, capabilities: maxIdle)
        #expect(dMaxIdle.segmentCount == 2)
        #expect(dMaxIdle.isSegmented)
        #expect(dMaxIdle.notice == nil)
        
        // 2. Ultra idle -> 4 segments
        let ultraIdle = HardwareMediaCapabilities(
            chipName: "Apple M3 Ultra", cpuCoreCount: 24, isAppleSilicon: true,
            h264HEVCEngineCount: 4, proResEngineCount: 4
        )
        let dUltra = HardwareCapabilities.resolveSegmentation(for: file, options: optionsAuto, capabilities: ultraIdle)
        #expect(dUltra.segmentCount == 4)
        
        // 3. M5 Max with 1 engine busy -> 1 segment on remaining idle engine + informative notice
        let maxOneBusy = HardwareMediaCapabilities(
            chipName: "Apple M5 Max", cpuCoreCount: 18, isAppleSilicon: true,
            h264HEVCEngineCount: 2, proResEngineCount: 2,
            activeAVEEnginesInUse: 1, activeProResEnginesInUse: 0
        )
        let dOneBusy = HardwareCapabilities.resolveSegmentation(for: file, options: optionsAuto, capabilities: maxOneBusy)
        #expect(dOneBusy.segmentCount == 1)
        #expect(dOneBusy.notice?.contains("1 of 2") == true)
        
        // 4. M5 Max with both engines busy -> single stream notice
        let maxAllBusy = HardwareMediaCapabilities(
            chipName: "Apple M5 Max", cpuCoreCount: 18, isAppleSilicon: true,
            h264HEVCEngineCount: 2, proResEngineCount: 2,
            activeAVEEnginesInUse: 2, activeProResEnginesInUse: 0
        )
        let dAllBusy = HardwareCapabilities.resolveSegmentation(for: file, options: optionsAuto, capabilities: maxAllBusy)
        #expect(dAllBusy.segmentCount == 1)
        #expect(dAllBusy.notice?.contains("busy") == true)
        
        // 5. M1 Base doing ProRes -> 0 ProRes hardware engines notice
        let m1Base = HardwareMediaCapabilities(
            chipName: "Apple M1", cpuCoreCount: 8, isAppleSilicon: true,
            h264HEVCEngineCount: 1, proResEngineCount: 0
        )
        let proResFile = Self.makeSampleMediaFile(duration: 120.0, action: .transcodeProRes)
        let dM1ProRes = HardwareCapabilities.resolveSegmentation(for: proResFile, options: RemuxOptions(targetContainer: .mov, outputURL: URL(fileURLWithPath: "/tmp/out.mov")), capabilities: m1Base)
        #expect(dM1ProRes.segmentCount == 1)
        #expect(dM1ProRes.notice?.contains("software fallback") == true)
        
        // 6. Exclusions: Passthrough copy, Short clip (<30s), 2-pass encode, HEVC main422
        let copyFile = Self.makeSampleMediaFile(duration: 120.0, action: .copy)
        #expect(HardwareCapabilities.resolveSegmentation(for: copyFile, options: optionsAuto, capabilities: maxIdle).segmentCount == 1)
        
        let shortFile = Self.makeSampleMediaFile(duration: 15.0, action: .transcodeH264_VT)
        #expect(HardwareCapabilities.resolveSegmentation(for: shortFile, options: optionsAuto, capabilities: maxIdle).segmentCount == 1)
        
        var twoPassFile = Self.makeSampleMediaFile(duration: 120.0, action: .transcodeHEVC_VT)
        twoPassFile.tracks[0].videoConfig.multiPass = true
        #expect(HardwareCapabilities.resolveSegmentation(for: twoPassFile, options: optionsAuto, capabilities: maxIdle).segmentCount == 1)
        
        var main422File = Self.makeSampleMediaFile(duration: 120.0, action: .transcodeHEVC_VT)
        main422File.tracks[0].videoConfig.profile = "main422"
        #expect(HardwareCapabilities.resolveSegmentation(for: main422File, options: optionsAuto, capabilities: maxIdle).segmentCount == 1)
        
        // 7. Manual override forces 3 segments even on 2-engine chip
        let manualOptions = RemuxOptions(targetContainer: .mp4, outputURL: URL(fileURLWithPath: "/tmp/out.mp4"), segmentedEncodingMode: .three)
        #expect(HardwareCapabilities.resolveSegmentation(for: file, options: manualOptions, capabilities: maxIdle).segmentCount == 3)
    }
    
    // MARK: - 2. Keyframe Boundary Probing & Parsing
    
    @Test("KeyframeProber CSV Parsing & Segment Boundary Builder")
    func testKeyframeProberParsingAndBoundaries() {
        let sampleCSV = """
        43.910000,___
        44.000000,K__
        44.041667,___
        44.950000,___
        45.000000,K__
        89.000000,K__
        """
        let parsed = KeyframeProber.parseKeyframeTimestamps(fromCSV: sampleCSV)
        #expect(parsed == [44.0, 45.0, 89.0])
        
        let boundaries = KeyframeProber.buildBoundaries(
            cutPoints: [44.0, 89.0],
            streamStart: 0.0,
            streamEnd: 120.0,
            minimumChunkDuration: 5.0
        )
        #expect(boundaries.count == 3)
        #expect(boundaries[0].seekTime == nil)
        #expect(boundaries[0].exactEndPTS == 44.0)
        #expect(boundaries[1].seekTime != nil)
        #expect(abs((boundaries[1].seekTime ?? 0) - (44.0 - 0.0005)) < 0.00001)
        #expect(boundaries[2].exactEndPTS == nil)
        #expect(boundaries[2].expectedDuration == 31.0)
        
        // Deduplicates cuts closer than minimumChunkDuration
        let deduped = KeyframeProber.buildBoundaries(
            cutPoints: [44.0, 45.0],
            streamStart: 0.0,
            streamEnd: 120.0,
            minimumChunkDuration: 5.0
        )
        #expect(deduped.count == 2)
    }
    
    // MARK: - 3. Segmented FFmpeg Command Builders
    
    @Test("Segmented Chunk, Sidecar, and Stitch FFmpeg Argument Builders")
    func testSegmentedArgumentBuilders() throws {
        var file = Self.makeSampleMediaFile(duration: 120.0, action: .transcodeHEVC_VT)
        file.tracks[1].action = .transcodeAAC_Stereo
        let options = RemuxOptions(targetContainer: .mp4, outputURL: URL(fileURLWithPath: "/tmp/final.mp4"), stripAllMetadata: true, stripChapters: false, fastStart: true)
        
        let boundary1 = VideoSegmentBoundary(index: 1, seekTime: 59.9995, exactStartPTS: 60.0, exactEndPTS: nil, expectedDuration: 60.0)
        let chunkArgs = RemuxEngine.buildSegmentedVideoChunkArguments(
            for: file,
            videoTrack: file.tracks[0],
            boundary: boundary1,
            options: options,
            chunkOutputURL: URL(fileURLWithPath: "/tmp/chunk_1.mp4")
        )
        #expect(chunkArgs.contains("-ss"))
        #expect(chunkArgs.contains("59.999500"))
        #expect(chunkArgs.contains("-hwaccel"))
        #expect(chunkArgs.contains("videotoolbox"))
        #expect(chunkArgs.contains("-an"))
        #expect(chunkArgs.contains("-sn"))
        #expect(chunkArgs.contains("hevc_videotoolbox"))
        #expect(!chunkArgs.contains("+faststart"))
        
        #expect(RemuxEngine.requiresSidecarAudioSubtitlePass(for: file.tracks, targetContainer: .mp4) == true)
        
        let sidecarArgs = RemuxEngine.buildSegmentedAudioSubtitleArguments(
            for: file,
            nonVideoTracks: [file.tracks[1]],
            options: options,
            sidecarOutputURL: URL(fileURLWithPath: "/tmp/sidecar.mp4")
        )
        #expect(sidecarArgs.contains("-vn"))
        #expect(sidecarArgs.contains("aac_at"))
        #expect(sidecarArgs.contains("-aac_at_mode:a:0"))
        
        let stitchArgs = try RemuxEngine.buildSegmentedStitchArguments(
            for: file,
            concatListURL: URL(fileURLWithPath: "/tmp/concat.txt"),
            sidecarAudioSubURL: URL(fileURLWithPath: "/tmp/sidecar.mp4"),
            options: options
        )
        #expect(stitchArgs.contains("-f"))
        #expect(stitchArgs.contains("concat"))
        #expect(stitchArgs.contains("-c"))
        #expect(stitchArgs.contains("copy"))
        #expect(stitchArgs.contains("-movflags"))
        #expect(stitchArgs.contains("+faststart"))
        #expect(stitchArgs.contains("hvc1"))
        #expect(stitchArgs.last == "/tmp/final.mp4")
    }
    
    // MARK: - 4. End-to-End Real FFmpeg Segmented Exports
    
    @Test("Real FFmpeg End-to-End 2-Segment H.264 & 3-Segment HEVC & ProRes Frame-Exact Stitch")
    func testRealFFmpegSegmentedExports() async throws {
        guard let (ffmpeg, ffprobe) = Self.resolveBinaries() else {
            return
        }
        
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("strata_seg_test_\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }
        
        // Create 12-second 23.976fps H.264 + AAC source with B-frames and GOP 24
        let sourceURL = workDir.appendingPathComponent("source_12s.mp4")
        let (genStatus, _, genErr) = try Self.runProcess(
            executable: ffmpeg,
            arguments: [
                "-y", "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", "testsrc2=duration=12:size=640x360:rate=24000/1001",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=12:sample_rate=48000",
                "-c:v", "libx264", "-g", "24", "-bf", "2", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "128k",
                sourceURL.path
            ]
        )
        #expect(genStatus == 0, "Sample generation failed: \(genErr)")
        
        let sourceFrames = try Self.probeFrameCount(url: sourceURL, ffprobePath: ffprobe)
        #expect(sourceFrames >= 280)
        
        var media = try await ProbePipeline.shared.probe(fileURL: sourceURL)
        #expect(media.tracks.count >= 2)
        
        // Test A: 2-Segment H.264 VideoToolbox + AAC Transcode (tests sidecar pass + exact stitch frame count)
        let h264OutURL = workDir.appendingPathComponent("out_2seg_h264.mp4")
        media.tracks[0].action = .transcodeH264_VT
        media.tracks[0].videoConfig = VideoEncodingConfig(bitrate: "2500k", allowFrameReordering: true)
        media.tracks[1].action = .transcodeAAC_Stereo
        
        let maxCaps = HardwareMediaCapabilities(
            chipName: "Test Silicon Max", cpuCoreCount: 16, isAppleSilicon: true,
            h264HEVCEngineCount: 2, proResEngineCount: 2
        )
        let h264Opts = RemuxOptions(
            targetContainer: .mp4,
            outputURL: h264OutURL,
            segmentedEncodingMode: .two,
            minSegmentationDuration: 6.0
        )
        
        let engineA = RemuxEngine()
        var sawSegmentedPhaseA = false
        var lastProgA: RemuxProgress?
        for await update in await engineA.run(
            file: media,
            options: h264Opts,
            ffmpegPathOverride: ffmpeg,
            ffprobePathOverride: ffprobe,
            capabilitiesOverride: maxCaps
        ) {
            if (update.activeSegments ?? 0) >= 2 { sawSegmentedPhaseA = true }
            lastProgA = update
        }
        
        #expect(sawSegmentedPhaseA)
        #expect((lastProgA?.progress ?? 0) >= 0.99)
        #expect(fm.fileExists(atPath: h264OutURL.path))
        let outFramesA = try Self.probeFrameCount(url: h264OutURL, ffprobePath: ffprobe)
        #expect(outFramesA == sourceFrames, "2-segment H.264 frame count mismatch: got \(outFramesA), expected \(sourceFrames)")
        let probedA = try await ProbePipeline.shared.probe(fileURL: h264OutURL)
        #expect(probedA.audioTracks.count == 1)
        #expect(abs(probedA.duration - media.duration) < 0.25)
        
        // Test B: 3-Segment HEVC VideoToolbox + Internal Copy Audio
        let hevcOutURL = workDir.appendingPathComponent("out_3seg_hevc.mp4")
        media.tracks[0].action = .transcodeHEVC_VT
        media.tracks[0].videoConfig = VideoEncodingConfig(bitrate: "2000k", allowFrameReordering: true)
        media.tracks[1].action = .copy
        
        let ultraCaps = HardwareMediaCapabilities(
            chipName: "Test Silicon Ultra", cpuCoreCount: 24, isAppleSilicon: true,
            h264HEVCEngineCount: 4, proResEngineCount: 4
        )
        let hevcOpts = RemuxOptions(
            targetContainer: .mp4,
            outputURL: hevcOutURL,
            segmentedEncodingMode: .three,
            minSegmentationDuration: 6.0
        )
        
        let engineB = RemuxEngine()
        var sawThreeSegments = false
        for await update in await engineB.run(
            file: media,
            options: hevcOpts,
            ffmpegPathOverride: ffmpeg,
            ffprobePathOverride: ffprobe,
            capabilitiesOverride: ultraCaps
        ) {
            if update.activeSegments == 3 { sawThreeSegments = true }
        }
        #expect(sawThreeSegments)
        let outFramesB = try Self.probeFrameCount(url: hevcOutURL, ffprobePath: ffprobe)
        #expect(outFramesB == sourceFrames, "3-segment HEVC frame count mismatch: got \(outFramesB), expected \(sourceFrames)")
        let probedB = try await ProbePipeline.shared.probe(fileURL: hevcOutURL)
        #expect(probedB.videoTracks.first?.codecName == "hevc")
        #expect(probedB.videoTracks.first?.codecTag == "hvc1")
        
        // Test C: 2-Segment Apple ProRes 422 (.mov)
        let proResOutURL = workDir.appendingPathComponent("out_2seg_prores.mov")
        media.tracks[0].action = .transcodeProRes
        media.tracks[0].videoConfig = VideoEncodingConfig(profile: "2")
        media.tracks[1].action = .copy
        
        let proResOpts = RemuxOptions(
            targetContainer: .mov,
            outputURL: proResOutURL,
            segmentedEncodingMode: .auto,
            minSegmentationDuration: 6.0
        )
        let engineC = RemuxEngine()
        for await _ in await engineC.run(
            file: media,
            options: proResOpts,
            ffmpegPathOverride: ffmpeg,
            ffprobePathOverride: ffprobe,
            capabilitiesOverride: maxCaps
        ) {}
        let outFramesC = try Self.probeFrameCount(url: proResOutURL, ffprobePath: ffprobe)
        #expect(outFramesC == sourceFrames, "2-segment ProRes frame count mismatch: got \(outFramesC), expected \(sourceFrames)")
        let probedC = try await ProbePipeline.shared.probe(fileURL: proResOutURL)
        #expect(probedC.videoTracks.first?.codecName == "prores")
        
        // Coordinator must have zero leaked active slots after completions
        let finalCounts = await HardwareSessionCoordinator.shared.activeCounts()
        #expect(finalCounts.ave == 0)
        #expect(finalCounts.proRes == 0)
    }
    
    @Test("Segmented Export Preserves Chapters, External Subtitles, and Cleans Up on Cancellation")
    func testSegmentedChaptersSubtitlesAndCancellation() async throws {
        guard let (ffmpeg, ffprobe) = Self.resolveBinaries() else {
            return
        }
        
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("strata_seg_sub_test_\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }
        
        // Create 10s source with 2 chapters via ffmetadata
        let metaURL = workDir.appendingPathComponent("meta.txt")
        let metaText = """
        ;FFMETADATA1
        [CHAPTER]
        TIMEBASE=1/1000
        START=0
        END=5000
        title=Chapter One
        [CHAPTER]
        TIMEBASE=1/1000
        START=5000
        END=10000
        title=Chapter Two
        """
        try metaText.write(to: metaURL, atomically: true, encoding: .utf8)
        
        let sourceURL = workDir.appendingPathComponent("source_chap.mp4")
        let (genStatus, _, genErr) = try Self.runProcess(
            executable: ffmpeg,
            arguments: [
                "-y", "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", "testsrc=duration=10:size=640x360:rate=30",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=10:sample_rate=48000",
                "-i", metaURL.path,
                "-map_metadata", "2", "-map_chapters", "2",
                "-c:v", "libx264", "-g", "30", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "128k",
                sourceURL.path
            ]
        )
        #expect(genStatus == 0, "Sample chapter video failed: \(genErr)")
        
        let srtURL = workDir.appendingPathComponent("sub.srt")
        try "1\n00:00:01,000 --> 00:00:04,000\nHello Strata\n".write(to: srtURL, atomically: true, encoding: .utf8)
        
        var media = try await ProbePipeline.shared.probe(fileURL: sourceURL)
        #expect(media.chapters.count == 2)
        let extSubs = try await ProbePipeline.shared.probeExternalTracks(fileURL: srtURL)
        media.tracks[0].action = .transcodeH264_VT
        media.tracks[0].videoConfig = VideoEncodingConfig(bitrate: "2500k")
        media.tracks.append(contentsOf: extSubs)
        
        let outURL = workDir.appendingPathComponent("out_chap_sub.mp4")
        let caps = HardwareMediaCapabilities(
            chipName: "Test Silicon Max", cpuCoreCount: 16, isAppleSilicon: true,
            h264HEVCEngineCount: 2, proResEngineCount: 2
        )
        let opts = RemuxOptions(
            targetContainer: .mp4,
            outputURL: outURL,
            stripAllMetadata: false,
            stripChapters: false,
            fastStart: true,
            segmentedEncodingMode: .two,
            minSegmentationDuration: 5.0
        )
        
        let engine = RemuxEngine()
        for await _ in await engine.run(
            file: media,
            options: opts,
            ffmpegPathOverride: ffmpeg,
            ffprobePathOverride: ffprobe,
            capabilitiesOverride: caps
        ) {}
        
        let outProbed = try await ProbePipeline.shared.probe(fileURL: outURL)
        #expect(outProbed.chapters.count == 2)
        #expect(outProbed.subtitleTracks.count == 1)
        #expect(outProbed.subtitleTracks.first?.codecName == "mov_text")
        #expect(try Self.probeFrameCount(url: outURL, ffprobePath: ffprobe) == 300)
        
        // Cancellation test: cancel immediately once progress arrives
        let cancelOutURL = workDir.appendingPathComponent("cancelled_out.mp4")
        let cancelOpts = RemuxOptions(
            targetContainer: .mp4,
            outputURL: cancelOutURL,
            segmentedEncodingMode: .two,
            minSegmentationDuration: 5.0
        )
        let cancelEngine = RemuxEngine()
        var updates = 0
        for await _ in await cancelEngine.run(
            file: media,
            options: cancelOpts,
            ffmpegPathOverride: ffmpeg,
            ffprobePathOverride: ffprobe,
            capabilitiesOverride: caps
        ) {
            updates += 1
            if updates == 1 {
                await cancelEngine.cancel()
            }
        }
        
        #expect(!fm.fileExists(atPath: cancelOutURL.path))
        let postCancelCounts = await HardwareSessionCoordinator.shared.activeCounts()
        #expect(postCancelCounts.ave == 0)
        #expect(postCancelCounts.proRes == 0)
    }
}
