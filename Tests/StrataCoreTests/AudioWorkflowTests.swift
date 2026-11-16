import Testing
import Foundation
@testable import StrataCore

@Suite("StrataCore Audio Workflow & Container Tests")
struct AudioWorkflowTests {
    
    @Test("Audio Container Classification and Properties")
    func testAudioContainerProperties() {
        #expect(ContainerFormat.m4a.isAudioContainer)
        #expect(ContainerFormat.wav.isAudioContainer)
        #expect(ContainerFormat.aiff.isAudioContainer)
        #expect(ContainerFormat.flac.isAudioContainer)
        #expect(ContainerFormat.mp3.isAudioContainer)
        #expect(ContainerFormat.opus.isAudioContainer)
        #expect(ContainerFormat.ogg.isAudioContainer)
        #expect(ContainerFormat.caf.isAudioContainer)
        #expect(ContainerFormat.mkv.isAudioContainer)
        
        #expect(ContainerFormat.mp4.isVideoContainer)
        #expect(!ContainerFormat.wav.isVideoContainer)
        #expect(!ContainerFormat.flac.isVideoContainer)
        #expect(!ContainerFormat.mp3.isVideoContainer)
        
        #expect(ContainerFormat.m4a.supportsMultiTrackAudio)
        #expect(ContainerFormat.mkv.supportsMultiTrackAudio)
        #expect(ContainerFormat.caf.supportsMultiTrackAudio)
        #expect(!ContainerFormat.mp3.supportsMultiTrackAudio)
        #expect(!ContainerFormat.wav.supportsMultiTrackAudio)
        #expect(!ContainerFormat.flac.supportsMultiTrackAudio)
        
        #expect(ContainerFormat.audioContainers.count == 9)
        #expect(ContainerFormat.videoContainers.count == 5)
    }
    
    @Test("MediaFile Suggested Container for Audio Files")
    func testSuggestedContainerForAudio() {
        let dummyTrack = MediaTrack(
            streamIndex: 0,
            mediaType: .audio,
            codecName: "pcm_s24le",
            isSelected: true,
            action: .copy
        )
        
        let wavFile = MediaFile(
            url: URL(fileURLWithPath: "/tmp/music.wav"),
            filename: "music.wav",
            fileSize: 10_000_000,
            containerFormat: "wav",
            containerLongName: "WAV / WAVE (Waveform Audio)",
            duration: 180.0,
            overallBitRate: 1411200,
            tags: [:],
            tracks: [dummyTrack],
            chapters: []
        )
        #expect(wavFile.suggestedContainer == ContainerFormat.wav)
        #expect(wavFile.isAudioOnly)
        #expect(!wavFile.hasVideoTrack)
        
        let flacTrack = MediaTrack(
            streamIndex: 0,
            mediaType: .audio,
            codecName: "flac",
            isSelected: true,
            action: .copy
        )
        let flacFile = MediaFile(
            url: URL(fileURLWithPath: "/tmp/album.flac"),
            filename: "album.flac",
            fileSize: 20_000_000,
            containerFormat: "flac",
            containerLongName: "raw FLAC",
            duration: 240.0,
            overallBitRate: 900000,
            tags: [:],
            tracks: [flacTrack],
            chapters: []
        )
        #expect(flacFile.suggestedContainer == ContainerFormat.flac)
        
        let m4aTrack = MediaTrack(
            streamIndex: 0,
            mediaType: .audio,
            codecName: "alac",
            isSelected: true,
            action: .copy
        )
        let m4aFile = MediaFile(
            url: URL(fileURLWithPath: "/tmp/song.m4a"),
            filename: "song.m4a",
            fileSize: 15_000_000,
            containerFormat: "mov,mp4,m4a",
            containerLongName: "QuickTime / MOV",
            duration: 200.0,
            overallBitRate: 850000,
            tags: [:],
            tracks: [m4aTrack],
            chapters: []
        )
        #expect(m4aFile.suggestedContainer == ContainerFormat.m4a)
    }
    
    @Test("RemuxEngine Audio Transcoding Command Generation")
    func testRemuxEngineAudioTranscodingArgs() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/input.wav")
        let outputURL = URL(fileURLWithPath: "/tmp/output.aiff")
        
        let audioTrack = MediaTrack(
            streamIndex: 0,
            mediaType: .audio,
            codecName: "pcm_s16le",
            isSelected: true,
            action: .transcodeAIFF
        )
        
        let mediaFile = MediaFile(
            url: sourceURL,
            filename: "input.wav",
            fileSize: 5_000_000,
            containerFormat: "wav",
            containerLongName: "WAV",
            duration: 120.0,
            overallBitRate: 1411200,
            tags: [:],
            tracks: [audioTrack],
            chapters: []
        )
        
        let options = RemuxOptions(
            targetContainer: .aiff,
            outputURL: outputURL,
            stripAllMetadata: true,
            stripChapters: true,
            fastStart: false,
            useHardwareAcceleration: false
        )
        
        let args = try RemuxEngine.buildArguments(for: mediaFile, options: options)
        #expect(args.contains("-i"))
        #expect(args.contains(sourceURL.path))
        #expect(args.contains("-map"))
        #expect(args.contains("0:0"))
        #expect(args.contains("-c:a:0"))
        #expect(args.contains("pcm_s16be"))
        #expect(args.last == outputURL.path)
    }
    
    @Test("RemuxEngine WAV to ALAC in M4A Container")
    func testWAVtoALACM4AArgs() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/master.wav")
        let outputURL = URL(fileURLWithPath: "/tmp/master.m4a")
        
        let audioTrack = MediaTrack(
            streamIndex: 0,
            mediaType: .audio,
            codecName: "pcm_s24le",
            isSelected: true,
            action: .transcodeALAC
        )
        
        let mediaFile = MediaFile(
            url: sourceURL,
            filename: "master.wav",
            fileSize: 50_000_000,
            containerFormat: "wav",
            containerLongName: "WAV",
            duration: 300.0,
            overallBitRate: 2304000,
            tags: [:],
            tracks: [audioTrack],
            chapters: []
        )
        
        let options = RemuxOptions(
            targetContainer: .m4a,
            outputURL: outputURL,
            stripAllMetadata: false,
            stripChapters: false,
            fastStart: true,
            useHardwareAcceleration: false
        )
        
        let args = try RemuxEngine.buildArguments(for: mediaFile, options: options)
        #expect(args.contains("-c:a:0"))
        #expect(args.contains("alac"))
        #expect(args.contains("+faststart"))
        #expect(args.last == outputURL.path)
    }
    
    @Test("RemuxEngine WAV to OGG Vorbis")
    func testWAVtoOGGVorbisArgs() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/voice.wav")
        let outputURL = URL(fileURLWithPath: "/tmp/voice.ogg")
        
        let audioTrack = MediaTrack(
            streamIndex: 0,
            mediaType: .audio,
            codecName: "pcm_s16le",
            isSelected: true,
            action: .transcodeVorbis
        )
        
        let mediaFile = MediaFile(
            url: sourceURL,
            filename: "voice.wav",
            fileSize: 10_000_000,
            containerFormat: "wav",
            containerLongName: "WAV",
            duration: 60.0,
            overallBitRate: 1411200,
            tags: [:],
            tracks: [audioTrack],
            chapters: []
        )
        
        let options = RemuxOptions(
            targetContainer: .ogg,
            outputURL: outputURL,
            stripAllMetadata: true,
            stripChapters: true,
            fastStart: false,
            useHardwareAcceleration: false
        )
        
        let args = try RemuxEngine.buildArguments(for: mediaFile, options: options)
        #expect(args.contains("-c:a:0"))
        #expect(args.contains("libvorbis"))
        #expect(args.last == outputURL.path)
    }
}
