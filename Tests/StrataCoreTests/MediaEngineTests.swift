import Testing
import Foundation
@preconcurrency import CoreMedia
@testable import StrataCore

@Suite("StrataCore Media Engine Tests")
struct MediaEngineTests {
    
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
    
    // MARK: - 1. Binary Capability Probing
    
    @Test("BinaryCapabilityProbe Parses Flags and Live Bundled FFmpeg Capabilities")
    func testBinaryCapabilityProbe() async throws {
        let parsed = FFmpegBinaryCapabilities.parse(
            pixFmtsOutput: "IO..P videotoolbox_vld  1  1",
            filtersOutput: " ... scale_vt  V->V\n ... transpose_vt V->V\n ... yadif_videotoolbox V->V\n ... loudnorm A->A\n ... xpsnr VV->V\n ... libvmaf VV->V",
            bsfsOutput: "dump_extra\nhevc_mp4toannexb",
            encodersOutput: " A.... aac_at\n V.... libsvtav1",
            decodersOutput: " V.... prores_raw",
            h264VTHelp: "  -realtime <boolean>\n  -spatial_aq <int>",
            hevcVTHelp: "  -realtime <boolean>\n  -spatial_aq <int>",
            proResVTHelp: "  -profile <int>",
            proResKsHelp: "  -vendor <string>"
        )
        #expect(parsed.supportsVideoToolboxVLD == true)
        #expect(parsed.h264VTSupportsSpatialAQ == true)
        #expect(parsed.hevcVTSupportsSpatialAQ == true)
        #expect(parsed.proResVTSupportsVendor == false)
        #expect(parsed.proResKsSupportsVendor == true)
        #expect(parsed.supportsScaleVT == true)
        #expect(parsed.supportsTransposeVT == true)
        #expect(parsed.supportsYadifVT == true)
        #expect(parsed.supportsAudioToolboxAAC == true)
        #expect(parsed.supportsLoudnorm == true)
        #expect(parsed.supportsXPSNR == true)
        #expect(parsed.supportsLibVMAF == true)
        #expect(parsed.supportsDumpExtraBSF == true)
        #expect(parsed.supportsProResRAWDecode == true)
        #expect(parsed.supportsSVTAV1 == true)
        
        if let (ffmpeg, _) = Self.resolveBinaries() {
            let probe = BinaryCapabilityProbe()
            let liveCaps = await probe.capabilities(for: ffmpeg)
            #expect(liveCaps.supportsVideoToolboxVLD)
            #expect(liveCaps.supportsAudioToolboxAAC)
            #expect(liveCaps.supportsScaleVT)
            #expect(liveCaps.supportsTransposeVT)
            #expect(liveCaps.supportsLoudnorm)
            #expect(liveCaps.supportsXPSNR)
            #expect(liveCaps.supportsLibVMAF)
            #expect(liveCaps.supportsDumpExtraBSF)
            #expect(liveCaps.supportsProResRAWDecode)
            #expect(liveCaps.supportsSVTAV1)
            if ffmpeg.contains("/opt/homebrew/") || ffmpeg.contains("/Resources/bin/") {
                #expect(liveCaps.supportsYadifVT)
            }
        }
        
        // Interlaced tracks must drop off VLD safely to CPU deinterlace when supportsYadifVT == false
        var interlacedTrack = MediaTrack(
            streamIndex: 0,
            mediaType: .video,
            codecName: "h264",
            width: 1920,
            height: 1080,
            pixelFormat: "yuv420p",
            fieldOrder: "tt",
            isSelected: true,
            action: .transcodeHEVC_VT
        )
        interlacedTrack.videoConfig = VideoEncodingConfig.default(for: .transcodeHEVC_VT)
        interlacedTrack.videoConfig.deinterlaceMode = .auto
        let noYadifCaps = FFmpegBinaryCapabilities(supportsYadifVT: false)
        #expect(ExecutionPlanner.canUseZeroCopyVLD(for: interlacedTrack, useHardwareAcceleration: true, binaryCapabilities: noYadifCaps) == false)
        let withYadifCaps = FFmpegBinaryCapabilities(supportsYadifVT: true)
        #expect(ExecutionPlanner.canUseZeroCopyVLD(for: interlacedTrack, useHardwareAcceleration: true, binaryCapabilities: withYadifCaps) == true)
    }
    
    // MARK: - 2. Three-Tier Execution Planner & Dolby Vision Guard
    
    @Test("ExecutionPlanner Routes Lossless, Zero-Copy VLD, Native 2-Pass HW, Hybrid SW, and DoVi Guard")
    func testExecutionPlannerMatrix() {
        let hev1Track = MediaTrack(
            streamIndex: 0,
            mediaType: .video,
            codecName: "hevc",
            codecTag: "hev1",
            width: 1920,
            height: 1080,
            pixelFormat: "yuv420p",
            isSelected: true,
            action: .copy
        )
        let audioCopy = MediaTrack(streamIndex: 1, mediaType: .audio, codecName: "aac", isSelected: true, action: .copy)
        let fileCopy = MediaFile(
            url: URL(fileURLWithPath: "/tmp/in.mkv"),
            filename: "in.mkv",
            fileSize: 1_000_000,
            containerFormat: "matroska",
            duration: 60.0,
            tracks: [hev1Track, audioCopy]
        )
        
        // Tier A: Lossless Remux + automatic hev1 -> hvc1 in MP4
        let planA = ExecutionPlanner.plan(
            for: fileCopy,
            options: RemuxOptions(targetContainer: .mp4, outputURL: URL(fileURLWithPath: "/tmp/out.mp4"))
        )
        #expect(planA.tier == .losslessRemuxOrSmartCut)
        #expect(planA.retagsHEVCToHVC1 == true)
        #expect(!planA.requiresDolbyVisionGuard)
        
        // Tier B (Zero-Copy HW VLD): HEVC single-pass Q65 from yuv420p
        var fileVLD = fileCopy
        fileVLD.tracks[0].action = .transcodeHEVC_VT
        fileVLD.tracks[0].videoConfig = VideoEncodingConfig.default(for: .transcodeHEVC_VT)
        let planVLD = ExecutionPlanner.plan(
            for: fileVLD,
            options: RemuxOptions(targetContainer: .mp4, outputURL: URL(fileURLWithPath: "/tmp/out.mp4"))
        )
        #expect(planVLD.tier == .zeroCopyHardwareTranscode)
        #expect(planVLD.usesZeroCopyVLD == true)
        #expect(planVLD.usesNativeVideoToolbox == false)
        
        // Tier B Guard: 8-bit yuv420p source -> HEVC Main10 must drop off VLD safely to Hybrid/CPU pixel conversion
        var fileMain10From8Bit = fileVLD
        fileMain10From8Bit.tracks[0].videoConfig.profile = "main10"
        let planHybrid = ExecutionPlanner.plan(
            for: fileMain10From8Bit,
            options: RemuxOptions(targetContainer: .mp4, outputURL: URL(fileURLWithPath: "/tmp/out.mp4"))
        )
        #expect(planHybrid.tier == .hybridOrSoftwareLibav)
        #expect(planHybrid.usesZeroCopyVLD == false)
        
        // Tier B (Native 2-Pass HW): MP4 input + MP4 output + 2-Pass VBR + no incompatible audio/sub filters
        var mp4Source = MediaFile(
            url: URL(fileURLWithPath: "/tmp/in.mp4"),
            filename: "in.mp4",
            fileSize: 1_000_000,
            containerFormat: "mov,mp4",
            duration: 30.0,
            tracks: [hev1Track, audioCopy]
        )
        mp4Source.tracks[0].action = .transcodeH264_VT
        mp4Source.tracks[0].videoConfig.rateControlMode = .twoPassVBR
        mp4Source.tracks[0].videoConfig.multiPass = true
        mp4Source.tracks[0].videoConfig.bitrate = "8000k"
        let planNative = ExecutionPlanner.plan(
            for: mp4Source,
            options: RemuxOptions(targetContainer: .mp4, outputURL: URL(fileURLWithPath: "/tmp/out.mp4"))
        )
        #expect(planNative.tier == .zeroCopyHardwareTranscode)
        #expect(planNative.usesNativeVideoToolbox == true)
        #expect(planNative.badgeTitle == "Native 2-Pass HW")
        
        // Prefer software 2-pass routes to Hybrid/SW libav
        let planSW = ExecutionPlanner.plan(
            for: mp4Source,
            options: RemuxOptions(targetContainer: .mp4, outputURL: URL(fileURLWithPath: "/tmp/out.mp4"), preferSoftwareTwoPass: true)
        )
        #expect(planSW.tier == .hybridOrSoftwareLibav)
        #expect(planSW.usesNativeVideoToolbox == false)
        
        // Dolby Vision Profile 5/8 RPU Guard
        var doviFile = fileVLD
        doviFile.tracks[0].dolbyVision = DolbyVisionInfo(profile: 5, level: 6, rpuPresent: true, blPresent: true, elPresent: false)
        let blockedPlan = ExecutionPlanner.plan(
            for: doviFile,
            options: RemuxOptions(targetContainer: .mp4, outputURL: URL(fileURLWithPath: "/tmp/out.mp4"), allowDolbyVisionReencode: false)
        )
        #expect(blockedPlan.requiresDolbyVisionGuard == true)
        #expect(blockedPlan.dolbyVisionWarningMessage?.contains("Profile 5") == true)
        
        let allowedPlan = ExecutionPlanner.plan(
            for: doviFile,
            options: RemuxOptions(targetContainer: .mp4, outputURL: URL(fileURLWithPath: "/tmp/out.mp4"), allowDolbyVisionReencode: true)
        )
        #expect(allowedPlan.requiresDolbyVisionGuard == false)
        
        // Plain-English vs Technical ExecutionPlan display strings & PerceptualQCMetric display labels
        #expect(planNative.videoKind == .hardwareTwoPass)
        #expect(planNative.hasAudioEncode == false)
        #expect(planNative.displayBadgeTitle(showTechnicalDetails: false) == "Hardware 2-Pass Encoding")
        #expect(planNative.displayBadgeTitle(showTechnicalDetails: true) == "Native 2-Pass HW")
        #expect(!planNative.displayReasonSummary(showTechnicalDetails: false).contains("VideoToolbox"))
        #expect(planNative.displayReasonSummary(showTechnicalDetails: false) == "Hardware 2-Pass H.264")
        #expect(planVLD.videoKind == .hardwareGPU)
        #expect(planVLD.displayBadgeTitle(showTechnicalDetails: false) == "Hardware Encoding")
        #expect(planVLD.displayReasonSummary(showTechnicalDetails: false) == "Hardware HEVC")
        #expect(!planVLD.displayReasonSummary(showTechnicalDetails: false).contains("videotoolbox"))
        #expect(planHybrid.videoKind == .hybrid)
        #expect(planHybrid.displayBadgeTitle(showTechnicalDetails: false) == "Hybrid Encoding")
        #expect(planHybrid.displayBadgeTitle(showTechnicalDetails: true) == "Hybrid HW + CPU")
        #expect(planHybrid.displayReasonSummary(showTechnicalDetails: false) == "Hardware HEVC")
        #expect(!planHybrid.displayReasonSummary(showTechnicalDetails: false).contains("VideoToolbox"))
        #expect(planSW.videoKind == .software)
        #expect(planSW.displayBadgeTitle(showTechnicalDetails: false) == "Software Encoding")
        #expect(planSW.displayBadgeTitle(showTechnicalDetails: true) == "Software libav")
        #expect(!planSW.displayReasonSummary(showTechnicalDetails: false).contains("libx264"))
        #expect(planSW.displayReasonSummary(showTechnicalDetails: false) == "Software 2-Pass H.264")
        #expect(ExecutionPlanner.displayTierLabel("Native 2-Pass HW", showTechnicalDetails: false) == "Hardware 2-Pass Encoding")
        #expect(ExecutionPlanner.displayTierLabel("Zero-Copy HW + Audio Encode", showTechnicalDetails: false) == "Hardware Encoding + Audio Encode")
        
        // Audio Encode suffix combinations & Video Copy + Audio Encode + Audio-only
        var fileCopyPlusAudio = fileCopy
        fileCopyPlusAudio.tracks[1].action = .transcodeAAC
        let planCopyAudio = ExecutionPlanner.plan(
            for: fileCopyPlusAudio,
            options: RemuxOptions(targetContainer: .mp4, outputURL: URL(fileURLWithPath: "/tmp/out.mp4"))
        )
        #expect(planCopyAudio.videoKind == .losslessCopy)
        #expect(planCopyAudio.hasAudioEncode == true)
        #expect(planCopyAudio.displayBadgeTitle(showTechnicalDetails: false) == "Lossless Remux + Audio Encode")
        #expect(planCopyAudio.displayBadgeTitle(showTechnicalDetails: true) == "Video Copy (hvc1) + Audio Encode")
        #expect(planCopyAudio.displayReasonSummary(showTechnicalDetails: false) == "Lossless Video Copy + AAC Audio")
        
        var fileHWPlusAudio = fileVLD
        fileHWPlusAudio.tracks[1].action = .transcodeAAC
        let planHWAudio = ExecutionPlanner.plan(
            for: fileHWPlusAudio,
            options: RemuxOptions(targetContainer: .mp4, outputURL: URL(fileURLWithPath: "/tmp/out.mp4"))
        )
        #expect(planHWAudio.videoKind == .hardwareGPU)
        #expect(planHWAudio.hasAudioEncode == true)
        #expect(planHWAudio.displayBadgeTitle(showTechnicalDetails: false) == "Hardware Encoding + Audio Encode")
        #expect(planHWAudio.displayBadgeTitle(showTechnicalDetails: true) == "Zero-Copy HW + Audio Encode")
        #expect(planHWAudio.displayReasonSummary(showTechnicalDetails: false) == "Hardware HEVC + AAC Audio")
        
        let audioOnlyFile = MediaFile(
            url: URL(fileURLWithPath: "/tmp/in.flac"),
            filename: "in.flac",
            fileSize: 500_000,
            containerFormat: "flac",
            duration: 20.0,
            tracks: [MediaTrack(streamIndex: 0, mediaType: .audio, codecName: "flac", action: .transcodeAAC)]
        )
        let planAudioOnly = ExecutionPlanner.plan(
            for: audioOnlyFile,
            options: RemuxOptions(targetContainer: .mp4, outputURL: URL(fileURLWithPath: "/tmp/out.m4a"))
        )
        #expect(planAudioOnly.videoKind == .none)
        #expect(planAudioOnly.hasAudioEncode == true)
        #expect(planAudioOnly.displayBadgeTitle(showTechnicalDetails: false) == "Audio Encode")
        #expect(planAudioOnly.displayReasonSummary(showTechnicalDetails: false) == "AAC Audio Encode")
        
        // ProRes keeps HW ProRes even if stale multiPass flag is set on videoConfig
        var proresFile = fileVLD
        proresFile.tracks[0].action = .transcodeProRes
        proresFile.tracks[0].videoConfig.profile = "4" // ProRes 4444 uses CPU pixel path -> Hybrid, NOT Software
        proresFile.tracks[0].videoConfig.multiPass = true
        let planProRes = ExecutionPlanner.plan(
            for: proresFile,
            options: RemuxOptions(targetContainer: .mov, outputURL: URL(fileURLWithPath: "/tmp/out.mov"))
        )
        #expect(planProRes.videoKind == .hybrid)
        #expect(planProRes.displayBadgeTitle(showTechnicalDetails: false) == "Hybrid Encoding")
        
        // AV1 and Uncompressed route to Software Encoding tier and hide libsvtav1 / v210 in plain mode
        for (action, profile, container, outExt, expectedPlain, expectedTechToken) in [
            (TrackAction.transcodeAV1, "auto", ContainerFormat.mp4, "mp4", "Software AV1", "SVT-AV1"),
            (TrackAction.transcodeUncompressed, "8bit_422", ContainerFormat.mov, "mov", "Uncompressed 8-Bit 4:2:2", "2vuy"),
            (TrackAction.transcodeUncompressed, "10bit_422", ContainerFormat.mov, "mov", "Uncompressed 10-Bit 4:2:2", "v210")
        ] {
            var swSpecFile = fileVLD
            swSpecFile.tracks[0].action = action
            swSpecFile.tracks[0].videoConfig = VideoEncodingConfig.default(for: action)
            swSpecFile.tracks[0].videoConfig.profile = profile
            let swPlan = ExecutionPlanner.plan(
                for: swSpecFile,
                options: RemuxOptions(targetContainer: container, outputURL: URL(fileURLWithPath: "/tmp/out.\(outExt)"))
            )
            #expect(swPlan.tier == .hybridOrSoftwareLibav)
            #expect(swPlan.videoKind == .software)
            #expect(swPlan.usesZeroCopyVLD == false)
            #expect(swPlan.displayBadgeTitle(showTechnicalDetails: false) == "Software Encoding")
            #expect(swPlan.displayReasonSummary(showTechnicalDetails: false) == expectedPlain)
            #expect(!swPlan.displayReasonSummary(showTechnicalDetails: false).contains("lib"))
            #expect(!swPlan.displayReasonSummary(showTechnicalDetails: false).contains("pipeline"))
            #expect(swPlan.displayReasonSummary(showTechnicalDetails: true).contains(expectedTechToken))
        }
        
        #expect(PerceptualQCMetric.xpsnr.displayName(showTechnicalDetails: false) == "Fast Quality Score")
        #expect(PerceptualQCMetric.libvmaf.displayName(showTechnicalDetails: false) == "Detailed Quality Score")
        #expect(PerceptualQCMetric.xpsnr.displayName(showTechnicalDetails: true).contains("XPSNR"))
        #expect(PerceptualQCMetric.libvmaf.displayName(showTechnicalDetails: true).contains("libvmaf"))
        #expect(mp4Source.displayContainerFormat == "MP4 (MPEG-4)")
    }
    
    // MARK: - 3. Rate Control, Zero-Copy VLD Filters, and Smart-Cut Foundations
    
    @Test("VideoToolbox Rate Control Exclusivity, Zero-Copy VLD Filter Chain, and v2.0 Smart-Cut Plan")
    func testRateControlFiltersAndSmartCut() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/src.mp4")
        let outURL = URL(fileURLWithPath: "/tmp/out.mp4")
        
        // 1. Default Constant Quality = 65 + Zero-Copy VLD filters (scale_vt + transpose_vt, no CPU scale)
        var trackCQ = MediaTrack(
            streamIndex: 0,
            mediaType: .video,
            codecName: "h264",
            width: 1920,
            height: 1080,
            pixelFormat: "yuv420p",
            isSelected: true,
            action: .transcodeHEVC_VT,
            videoConfig: VideoEncodingConfig.default(for: .transcodeHEVC_VT)
        )
        trackCQ.videoConfig.resizeOption = .hd720
        trackCQ.videoConfig.rotation = .clockwise90
        trackCQ.videoConfig.colorSpace = .rec709
        
        let argsCQ = try RemuxEngine.buildArguments(
            for: MediaFile(url: sourceURL, filename: "src.mp4", fileSize: 1000, containerFormat: "mp4", duration: 10, tracks: [trackCQ]),
            options: RemuxOptions(targetContainer: .mp4, outputURL: outURL)
        )
        #expect(argsCQ.contains("-hwaccel_output_format"))
        #expect(argsCQ.contains("videotoolbox_vld"))
        #expect(argsCQ.contains("-q:v:0"))
        #expect(argsCQ.contains("65"))
        #expect(argsCQ.contains("-realtime:v:0"))
        #expect(argsCQ.contains("-spatial_aq:v:0"))
        #expect(!argsCQ.contains("-b:v:0"), "Must never mix -b:v with -q:v on VideoToolbox")
        #expect(argsCQ.contains("-tag:v:0"))
        #expect(argsCQ.contains("hvc1"))
        #expect(argsCQ.contains { $0.contains("transpose_vt=dir=clock") && $0.contains("scale_vt=w=1280:h=-2") })
        #expect(!argsCQ.contains { $0.contains("yadif") }, "Progressive source must not run yadif")
        
        // 2. Interlaced source activates yadif_videotoolbox when supported, or safely falls back to CPU yadif otherwise
        var trackInterlaced = trackCQ
        trackInterlaced.fieldOrder = "tt"
        let argsInterlacedVLD = try RemuxEngine.buildArguments(
            for: MediaFile(url: sourceURL, filename: "src.mp4", fileSize: 1000, containerFormat: "mp4", duration: 10, tracks: [trackInterlaced]),
            options: RemuxOptions(targetContainer: .mp4, outputURL: outURL),
            binaryCapabilities: FFmpegBinaryCapabilities(supportsYadifVT: true)
        )
        #expect(argsInterlacedVLD.contains { $0.contains("yadif_videotoolbox=mode=send_frame:parity=auto:deint=interlaced") })
        
        let argsInterlacedFallback = try RemuxEngine.buildArguments(
            for: MediaFile(url: sourceURL, filename: "src.mp4", fileSize: 1000, containerFormat: "mp4", duration: 10, tracks: [trackInterlaced]),
            options: RemuxOptions(targetContainer: .mp4, outputURL: outURL),
            binaryCapabilities: .assumedModernDefaults
        )
        #expect(argsInterlacedFallback.contains { $0.contains("yadif=0:-1:1") })
        #expect(!argsInterlacedFallback.contains { $0.contains("yadif_videotoolbox") })
        
        // 3. Constrained Average Bitrate emits -b:v + -maxrate + -bufsize, NEVER -q:v
        var trackABR = trackCQ
        trackABR.videoConfig.resizeOption = .original
        trackABR.videoConfig.rotation = .none
        trackABR.videoConfig.colorSpace = nil
        trackABR.videoConfig.rateControlMode = .averageBitrate
        trackABR.videoConfig.bitrate = "12000k"
        trackABR.videoConfig.maxBitrate = "18000k"
        let argsABR = try RemuxEngine.buildArguments(
            for: MediaFile(url: sourceURL, filename: "src.mp4", fileSize: 1000, containerFormat: "mp4", duration: 10, tracks: [trackABR]),
            options: RemuxOptions(targetContainer: .mp4, outputURL: outURL)
        )
        #expect(argsABR.contains("-b:v:0"))
        #expect(argsABR.contains("12000k"))
        #expect(argsABR.contains("-maxrate:v:0"))
        #expect(argsABR.contains("18000k"))
        #expect(argsABR.contains("-bufsize:v:0"))
        #expect(argsABR.contains("36000k"))
        #expect(!argsABR.contains("-q:v:0"), "Must never mix -q:v with -b:v on VideoToolbox")
        
        // 4. Smart-Cut non-UI boundary plan & argument builders
        let keyframeAligned = KeyframeProber.planSmartCutSegments(
            trimRange: MediaTrimRange(inTime: 10.0, outTime: 30.0),
            keyframes: [0.0, 10.0, 20.0, 30.0]
        )
        #expect(!keyframeAligned.requiresEdgeReencode)
        #expect(keyframeAligned.losslessCopyRange == MediaTrimRange(inTime: 10.0, outTime: 30.0))
        
        let openGOP = KeyframeProber.planSmartCutSegments(
            trimRange: MediaTrimRange(inTime: 7.5, outTime: 33.2),
            keyframes: [0.0, 10.0, 20.0, 30.0, 40.0]
        )
        #expect(openGOP.requiresEdgeReencode)
        #expect(openGOP.leadingReencodeRange == MediaTrimRange(inTime: 7.5, outTime: 10.0))
        #expect(openGOP.losslessCopyRange == MediaTrimRange(inTime: 10.0, outTime: 30.0))
        #expect(openGOP.trailingReencodeRange == MediaTrimRange(inTime: 30.0, outTime: 33.2))
        
        let edgeArgs = KeyframeProber.buildSmartCutEdgeArguments(
            sourceURL: sourceURL,
            videoTrack: MediaTrack(
                streamIndex: 0,
                mediaType: .video,
                codecName: "hevc",
                profile: "Main 10",
                codecLevel: 150,
                colorSpace: "bt2020nc",
                colorPrimaries: "bt2020",
                colorTransfer: "smpte2084",
                timeBase: "1/90000"
            ),
            edgeRange: MediaTrimRange(inTime: 7.5, outTime: 10.0),
            isLeadingEdge: true,
            isMP4Like: true,
            outputURL: URL(fileURLWithPath: "/tmp/lead.ts")
        )
        #expect(edgeArgs.contains("-frames_after:v:0"))
        #expect(edgeArgs.contains("-bsf:v:0"))
        #expect(edgeArgs.contains("dump_extra"))
        #expect(edgeArgs.contains("-video_track_timescale:v:0"))
        #expect(edgeArgs.contains("90000"))
        
        let stitchSmartArgs = KeyframeProber.buildSmartCutStitchArguments(
            concatListURL: URL(fileURLWithPath: "/tmp/concat.txt"),
            isHEVC: true,
            isMP4Like: true,
            outputURL: outURL
        )
        #expect(stitchSmartArgs.contains("-bsf:v:0"))
        #expect(stitchSmartArgs.contains("dump_extra"))
        #expect(stitchSmartArgs.contains("-avoid_negative_ts"))
        #expect(stitchSmartArgs.contains("make_zero"))
        #expect(stitchSmartArgs.contains("hvc1"))
    }
    
    // MARK: - 4. AudioToolbox, 2-Pass EBU R128 Loudnorm, HDR10 Probe & Perceptual QC Parsers
    
    @Test("AudioToolbox VBR/Loudnorm Builders and HDR10 / XPSNR / libvmaf Parsers")
    func testAudioLoudnormHDRAndQCParsers() throws {
        var audioTrack = MediaTrack(
            streamIndex: 1,
            mediaType: .audio,
            codecName: "ac3",
            channels: 6,
            sampleRate: "48000",
            isSelected: true,
            action: .transcodeAAC,
            audioConfig: AudioEncodingConfig.default(for: .transcodeAAC)
        )
        audioTrack.audioConfig.loudnessTarget = .streaming14
        
        let videoTrack = MediaTrack(streamIndex: 0, mediaType: .video, codecName: "h264", isSelected: true, action: .copy)
        let file = MediaFile(
            url: URL(fileURLWithPath: "/tmp/in.mkv"),
            filename: "in.mkv",
            fileSize: 1000,
            containerFormat: "matroska",
            duration: 10,
            tracks: [videoTrack, audioTrack]
        )
        
        let pass1Loud = RemuxEngine.buildLoudnormAnalysisArguments(for: file, track: audioTrack)
        #expect(pass1Loud != nil)
        #expect(pass1Loud?.contains { $0.contains("loudnorm=I=-14.0") && $0.contains("print_format=json") } == true)
        
        let sampleLoudJSON = """
        {
            "input_i" : "-21.45",
            "input_tp" : "-3.10",
            "input_lra" : "6.20",
            "input_thresh" : "-32.10",
            "target_offset" : "7.45"
        }
        """
        let measured = RemuxEngine.parseLoudnormJSON(from: sampleLoudJSON)
        #expect(measured != nil)
        #expect(abs((measured?.inputI ?? 0) - (-21.45)) < 0.01)
        
        let pass2Args = try RemuxEngine.buildArguments(
            for: file,
            options: RemuxOptions(targetContainer: .mp4, outputURL: URL(fileURLWithPath: "/tmp/out.mp4")),
            loudnessMeasurements: [audioTrack.id: measured!]
        )
        #expect(pass2Args.contains("aac_at"))
        #expect(pass2Args.contains("-aac_at_mode:a:0"))
        #expect(pass2Args.contains("vbr"))
        #expect(pass2Args.contains("-q:a:0"))
        #expect(pass2Args.contains("2"))
        #expect(pass2Args.contains("-ar:a:0"))
        #expect(pass2Args.contains("48000"))
        #expect(pass2Args.contains { $0.contains("linear=true") && $0.contains("measured_I=-21.45") })
        
        // HDR10 x265 SEI formatting & technical summary
        let md = HDRMasteringDisplay(
            redX: 0.680, redY: 0.320,
            greenX: 0.265, greenY: 0.690,
            blueX: 0.150, blueY: 0.060,
            whitePointX: 0.3127, whitePointY: 0.3290,
            minLuminance: 0.005, maxLuminance: 1000.0
        )
        #expect(md.formattedSummary?.contains("Display P3") == true)
        #expect(md.x265MasterDisplayParameter == "G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)")
        let cll = HDRContentLightLevel(maxCLL: 1000, maxFALL: 400)
        #expect(cll.x265MaxCLLParameter == "1000,400")
        
        // Perceptual QC parsers
        let xpsnr = PerceptualQCRunner.parseXPSNR(stderr: "[Parsed_xpsnr_1] XPSNR y: 43.18 u: 45.22 v: 46.10 (min: 40.00)")
        #expect(xpsnr?.metric == .xpsnr)
        #expect(abs((xpsnr?.primaryScore ?? 0) - 43.18) < 0.01)
        #expect(xpsnr?.summary == "XPSNR Y: 43.18 dB")
        
        let vmafJSON = #"{"pooled_metrics":{"vmaf":{"mean":96.42,"min":91.5,"max":99.1}}}"#.data(using: .utf8)!
        let vmaf = PerceptualQCRunner.parseVMAFJSON(data: vmafJSON)
        #expect(vmaf?.metric == .libvmaf)
        #expect(abs((vmaf?.primaryScore ?? 0) - 96.42) < 0.01)
        #expect(vmaf?.summary.contains("96.42") == true)
    }
    
    // MARK: - 5. Live End-to-End Hardware VLD, Native 2-Pass VT, HDR10 Probe, Loudnorm, and QC
    
    @Test("Live Zero-Copy VLD Filters, Native 2-Pass VT Encode, Loudnorm, HDR10 Probe, and Perceptual QC")
    func testLiveMediaEngineEndToEnd() async throws {
        // Check native IOSurface pixel buffer pool sharing first
        let poolShared = NativeVideoToolboxEngine.probeSharedPixelBufferPoolSupport(
            width: 640,
            height: 360,
            codec: kCMVideoCodecType_HEVC,
            isTenBit: false
        )
        #expect(poolShared == true, "Apple Silicon VideoToolbox must support IOSurface-shared CVPixelBufferPool")
        
        guard let (ffmpeg, ffprobe) = Self.resolveBinaries() else {
            return
        }
        
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("strata_engine_live_\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }
        
        // Generate 3s 640x360 yuv420p H.264 + 48kHz audio source
        let srcURL = workDir.appendingPathComponent("src.mp4")
        let (genStatus, _, genErr) = try Self.runProcess(
            executable: ffmpeg,
            arguments: [
                "-y", "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", "testsrc2=duration=3:size=640x360:rate=30",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=3:sample_rate=48000",
                "-c:v", "libx264", "-g", "30", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "128k",
                srcURL.path
            ]
        )
        #expect(genStatus == 0, "Sample gen failed: \(genErr)")
        
        var media = try await ProbePipeline.shared.probe(fileURL: srcURL)
        #expect(media.videoTracks.first?.pixelFormat == "yuv420p")
        #expect(media.videoTracks.first?.timeBase != nil)
        
        // Test A: Live Zero-Copy VLD resize + 2-pass loudnorm + XPSNR QC (plus VLD rotation)
        let vldOutURL = workDir.appendingPathComponent("out_vld_qc.mp4")
        media.tracks[0].action = .transcodeHEVC_VT
        media.tracks[0].videoConfig = VideoEncodingConfig.default(for: .transcodeHEVC_VT)
        media.tracks[0].videoConfig.qualityScale = 72
        media.tracks[0].videoConfig.resizeOption = .hd720
        media.tracks[1].action = .transcodeAAC
        media.tracks[1].audioConfig = AudioEncodingConfig.default(for: .transcodeAAC)
        media.tracks[1].audioConfig.loudnessTarget = .podcast16
        
        let vldOpts = RemuxOptions(
            targetContainer: .mp4,
            outputURL: vldOutURL,
            segmentedEncodingMode: .off,
            perceptualQCMetric: .xpsnr
        )
        let engineA = RemuxEngine(coordinator: HardwareSessionCoordinator())
        var lastA: RemuxProgress?
        for await u in await engineA.run(file: media, options: vldOpts, ffmpegPathOverride: ffmpeg, ffprobePathOverride: ffprobe) {
            lastA = u
        }
        #expect((lastA?.progress ?? 0) >= 0.99)
        #expect(lastA?.executionTierLabel == "Zero-Copy HW + Audio Encode")
        #expect(lastA?.qcSummary?.contains("XPSNR Y:") == true)
        let probedVLD = try await ProbePipeline.shared.probe(fileURL: vldOutURL)
        #expect(probedVLD.videoTracks.first?.codecName == "hevc")
        #expect(probedVLD.videoTracks.first?.codecTag == "hvc1")
        #expect(probedVLD.videoTracks.first?.width == 1280)
        #expect(probedVLD.videoTracks.first?.height == 720)
        
        // Test A2: Live Zero-Copy VLD transpose_vt rotation
        let rotOutURL = workDir.appendingPathComponent("out_rot.mp4")
        var rotMedia = try await ProbePipeline.shared.probe(fileURL: srcURL)
        rotMedia.tracks[0].action = .transcodeHEVC_VT
        rotMedia.tracks[0].videoConfig.rotation = .clockwise90
        let rotEngine = RemuxEngine(coordinator: HardwareSessionCoordinator())
        for await _ in await rotEngine.run(
            file: rotMedia,
            options: RemuxOptions(targetContainer: .mp4, outputURL: rotOutURL, segmentedEncodingMode: .off),
            ffmpegPathOverride: ffmpeg,
            ffprobePathOverride: ffprobe
        ) {}
        let probedRot = try await ProbePipeline.shared.probe(fileURL: rotOutURL)
        #expect((probedRot.videoTracks.first?.height ?? 0) > (probedRot.videoTracks.first?.width ?? 0))
        
        // Test B: Live Native 2-Pass VideoToolbox encode with libvmaf QC
        let nativeOutURL = workDir.appendingPathComponent("out_native_2pass.mp4")
        var nativeMedia = try await ProbePipeline.shared.probe(fileURL: srcURL)
        nativeMedia.tracks[0].action = .transcodeHEVC_VT
        nativeMedia.tracks[0].videoConfig = VideoEncodingConfig(
            bitrate: "2500k",
            multiPass: true,
            rateControlMode: .twoPassVBR,
            maxBitrate: "4000k"
        )
        nativeMedia.tracks[1].action = .copy
        let nativeOpts = RemuxOptions(
            targetContainer: .mp4,
            outputURL: nativeOutURL,
            segmentedEncodingMode: .off,
            perceptualQCMetric: .libvmaf
        )
        let engineB = RemuxEngine(coordinator: HardwareSessionCoordinator())
        var sawSharedPool = false
        var lastB: RemuxProgress?
        for await u in await engineB.run(file: nativeMedia, options: nativeOpts, ffmpegPathOverride: ffmpeg, ffprobePathOverride: ffprobe) {
            if u.pixelBufferPoolShared == true { sawSharedPool = true }
            lastB = u
        }
        #expect(sawSharedPool == true)
        #expect(lastB?.executionTierLabel == "Native 2-Pass HW")
        #expect(lastB?.qcSummary?.contains("VMAF:") == true)
        let probedNative = try await ProbePipeline.shared.probe(fileURL: nativeOutURL)
        #expect(probedNative.videoTracks.first?.codecName == "hevc")
        #expect(probedNative.audioTracks.count == 1)
        
        // Test C: Dolby Vision Guard blocks transcode cleanly without creating output file
        var doviMedia = nativeMedia
        doviMedia.tracks[0].dolbyVision = DolbyVisionInfo(profile: 5, rpuPresent: true)
        let blockedOutURL = workDir.appendingPathComponent("blocked_dovi.mp4")
        let blockedEngine = RemuxEngine(coordinator: HardwareSessionCoordinator())
        var lastBlocked: RemuxProgress?
        for await u in await blockedEngine.run(
            file: doviMedia,
            options: RemuxOptions(targetContainer: .mp4, outputURL: blockedOutURL, allowDolbyVisionReencode: false),
            ffmpegPathOverride: ffmpeg,
            ffprobePathOverride: ffprobe
        ) {
            lastBlocked = u
        }
        #expect(lastBlocked?.speed == "Blocked")
        #expect(!fm.fileExists(atPath: blockedOutURL.path))
        
        // Test D: Real HDR10 MKV (ST 2086 + MaxCLL) Probing
        let hdrURL = workDir.appendingPathComponent("hdr10.mkv")
        let (hdrStatus, _, hdrErr) = try Self.runProcess(
            executable: ffmpeg,
            arguments: [
                "-y", "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", "testsrc2=duration=0.2:size=128x128:rate=25",
                "-c:v", "libx265", "-pix_fmt", "yuv420p10le",
                "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc",
                "-x265-params", "hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1):max-cll=1000,400:log-level=error",
                hdrURL.path
            ]
        )
        if hdrStatus == 0 {
            let hdrProbed = try await ProbePipeline.shared.probe(fileURL: hdrURL)
            #expect(hdrProbed.videoTracks.first?.masteringDisplay?.maxLuminance == 1000.0)
            #expect(hdrProbed.videoTracks.first?.contentLightLevel?.maxCLL == 1000)
            #expect(hdrProbed.videoTracks.first?.contentLightLevel?.maxFALL == 400)
            #expect(hdrProbed.technicalSummaryText.contains("HDR10 Mastering"))
            #expect(hdrProbed.technicalSummaryText.contains("MaxCLL / MaxFALL"))
        } else {
            Issue.record("Synthetic HDR10 sample generation failed: \(hdrErr)")
        }
    }
}
