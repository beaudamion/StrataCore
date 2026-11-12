import Foundation
@preconcurrency import AVFoundation
import VideoToolbox
import CoreMedia
import CoreVideo

public struct NativeEncodeResult: Equatable, Sendable {
    public let succeeded: Bool
    public let usedTwoPass: Bool
    public let pixelBufferPoolShared: Bool
    public let errorMessage: String?
    
    public init(
        succeeded: Bool,
        usedTwoPass: Bool,
        pixelBufferPoolShared: Bool,
        errorMessage: String? = nil
    ) {
        self.succeeded = succeeded
        self.usedTwoPass = usedTwoPass
        self.pixelBufferPoolShared = pixelBufferPoolShared
        self.errorMessage = errorMessage
    }
}

/// Native Swift hardware encoding pipeline backed by `AVAssetReader` (IOSurface),
/// `VTCompressionSession` (`MultiPassStorage`, `DataRateLimits`, `PreserveDynamicHDRMetadata`),
/// and `AVAssetWriter`.
public actor NativeVideoToolboxEngine {
    private var isCancelled: Bool = false
    
    public init() {}
    
    public func cancel() {
        isCancelled = true
    }
    
    /// Verifies whether `VTCompressionSession` accepts `IOSurface`-backed `CVPixelBufferPool` sharing.
    public static func probeSharedPixelBufferPoolSupport(
        width: Int32 = 640,
        height: Int32 = 360,
        codec: CMVideoCodecType = kCMVideoCodecType_HEVC,
        isTenBit: Bool = false
    ) -> Bool {
        let pixelFormat: OSType = isTenBit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue!
        ]
        let sourceAttrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferPixelFormatTypeKey: NSNumber(value: pixelFormat),
            kCVPixelBufferWidthKey: NSNumber(value: width),
            kCVPixelBufferHeightKey: NSNumber(value: height)
        ]
        
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codec,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: sourceAttrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            return false
        }
        defer { VTCompressionSessionInvalidate(session) }
        
        var rawBoolPtr: UnsafeMutableRawPointer?
        let propStatus = VTSessionCopyProperty(
            session,
            key: kVTCompressionPropertyKey_PixelBufferPoolIsShared,
            allocator: kCFAllocatorDefault,
            valueOut: &rawBoolPtr
        )
        if propStatus == noErr, let rawBoolPtr {
            let cfBool = Unmanaged<AnyObject>.fromOpaque(rawBoolPtr).takeRetainedValue()
            if let flag = cfBool as? Bool {
                return flag
            }
        }
        // Create pixel buffer from pool once so VideoToolbox materializes pool metadata
        if let pool = VTCompressionSessionGetPixelBufferPool(session) {
            var px: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &px)
            if let px {
                return CVPixelBufferGetIOSurface(px) != nil
            }
        }
        return false
    }
    
    /// Executes a native VideoToolbox 2-Pass VBR encode while streaming `RemuxProgress` updates.
    public func runTwoPassEncode(
        file: MediaFile,
        videoTrack: MediaTrack,
        options: RemuxOptions,
        targetBitrateBps: Int,
        maxBitrateBps: Int?,
        notice: String?,
        progressHandler: @Sendable (RemuxProgress) -> Void
    ) async -> NativeEncodeResult {
        isCancelled = false
        let asset = AVURLAsset(url: file.url)
        let totalDuration = max(0.01, file.duration)
        
        do {
            let avVideoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let sourceAVVideo = avVideoTracks.first else {
                return NativeEncodeResult(
                    succeeded: false,
                    usedTwoPass: false,
                    pixelBufferPoolShared: false,
                    errorMessage: "No video track found for native VideoToolbox pipeline."
                )
            }
            let avAudioTracks = try await asset.loadTracks(withMediaType: .audio)
            let selectedAudioTracks = file.tracks.filter { $0.isSelected && $0.mediaType == .audio && !$0.isExternal }
            
            let naturalSize = try await sourceAVVideo.load(.naturalSize)
            let width = max(16, Int32(naturalSize.width.rounded()))
            let height = max(16, Int32(naturalSize.height.rounded()))
            
            let cfg = videoTrack.videoConfig
            let profLower = cfg.profile?.lowercased()
            let wantsHEVC = (videoTrack.action == .transcodeHEVC_VT)
            let isTenBit = wantsHEVC && (
                profLower == "main10"
                || profLower == "main42210"
                || ((profLower == nil || profLower == "auto") && (videoTrack.bitDepth ?? 8) >= 10)
            )
            let pixelFormat: OSType = isTenBit
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("strata_native_vt_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }
            
            let storageURL = tempDir.appendingPathComponent("multipass.storage")
            let pass1URL = tempDir.appendingPathComponent("pass1.\(options.targetContainer == .mov ? "mov" : "mp4")")
            
            var multiPassStorage: VTMultiPassStorage?
            let storageStatus = VTMultiPassStorageCreate(
                allocator: kCFAllocatorDefault,
                fileURL: storageURL as CFURL,
                timeRange: CMTimeRange.invalid,
                options: nil,
                multiPassStorageOut: &multiPassStorage
            )
            guard storageStatus == noErr, let storage = multiPassStorage else {
                return NativeEncodeResult(
                    succeeded: false,
                    usedTwoPass: false,
                    pixelBufferPoolShared: false,
                    errorMessage: "Failed to create VTMultiPassStorage (\(storageStatus))."
                )
            }
            defer {
                VTMultiPassStorageClose(storage)
            }
            
            let codecType: CMVideoCodecType = wantsHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
            let encoderSpec: [CFString: Any] = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue!
            ]
            let sourceAttrs: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferPixelFormatTypeKey: NSNumber(value: pixelFormat),
                kCVPixelBufferWidthKey: NSNumber(value: width),
                kCVPixelBufferHeightKey: NSNumber(value: height)
            ]
            
            var compressionSession: VTCompressionSession?
            let createStatus = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: width,
                height: height,
                codecType: codecType,
                encoderSpecification: encoderSpec as CFDictionary,
                imageBufferAttributes: sourceAttrs as CFDictionary,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &compressionSession
            )
            guard createStatus == noErr, let session = compressionSession else {
                return NativeEncodeResult(
                    succeeded: false,
                    usedTwoPass: false,
                    pixelBufferPoolShared: false,
                    errorMessage: "VTCompressionSessionCreate failed (\(createStatus))."
                )
            }
            defer { VTCompressionSessionInvalidate(session) }
            
            var poolSharedPtr: UnsafeMutableRawPointer?
            let sharedStatus = VTSessionCopyProperty(
                session,
                key: kVTCompressionPropertyKey_PixelBufferPoolIsShared,
                allocator: kCFAllocatorDefault,
                valueOut: &poolSharedPtr
            )
            var isPoolShared = false
            if sharedStatus == noErr, let poolSharedPtr {
                let cfVal = Unmanaged<AnyObject>.fromOpaque(poolSharedPtr).takeRetainedValue()
                isPoolShared = (cfVal as? Bool) == true
            }
            if !isPoolShared, let pool = VTCompressionSessionGetPixelBufferPool(session) {
                var testBuf: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &testBuf)
                if let testBuf {
                    isPoolShared = (CVPixelBufferGetIOSurface(testBuf) != nil)
                }
            }
            
            // Offline high-quality properties (note: NEVER set SpatialAdaptiveQPLevel alongside MultiPassStorage)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_AllowFrameReordering,
                value: cfg.allowFrameReordering ? kCFBooleanTrue : kCFBooleanFalse
            )
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PreserveDynamicHDRMetadata, value: kCFBooleanTrue)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MultiPassStorage, value: storage)
            
            if let profileConstant = Self.resolveProfileLevel(for: videoTrack.action, config: cfg, isTenBit: isTenBit) {
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profileConstant)
            }
            
            if #available(macOS 26.0, *), maxBitrateBps != nil {
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_VariableBitRate, value: NSNumber(value: UInt32(max(100_000, targetBitrateBps))))
                if let maxBps = maxBitrateBps {
                    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_VBVMaxBitRate, value: NSNumber(value: UInt32(max(targetBitrateBps, maxBps))))
                }
            } else {
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: max(100_000, targetBitrateBps)))
            }
            
            if let maxBps = maxBitrateBps, maxBps > 0 {
                let bytesPerSec = Double(max(targetBitrateBps, maxBps)) / 8.0
                let limits: [NSNumber] = [NSNumber(value: bytesPerSec), NSNumber(value: 1.0)]
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
            }
            
            if let kf = cfg.keyFrameInterval, kf > 0 {
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: kf))
            }
            
            Self.applyColorProperties(to: session, track: videoTrack, config: cfg)
            VTCompressionSessionPrepareToEncodeFrames(session)
            
            progressHandler(RemuxProgress(
                progress: 0.0,
                currentTime: 0,
                totalTime: totalDuration,
                speed: "Pass 1/2 • Starting...",
                phaseLabel: "Native 2-Pass HW",
                notice: notice,
                executionTierLabel: "Native 2-Pass HW",
                pixelBufferPoolShared: isPoolShared
            ))
            
            // Pass 1 (analysis + fallback write into pass1URL)
            let pass1OK = try await encodeVideoPass(
                asset: asset,
                sourceVideoTrack: sourceAVVideo,
                session: session,
                pixelFormat: pixelFormat,
                destinationURL: pass1URL,
                container: options.targetContainer,
                fastStart: options.fastStart,
                audioTracks: [],
                stripMetadata: options.stripAllMetadata,
                timeRanges: nil,
                totalDuration: totalDuration,
                progressOffset: 0.0,
                progressScale: 0.5,
                speedPrefix: "Pass 1/2",
                notice: notice,
                isPoolShared: isPoolShared,
                progressHandler: progressHandler
            )
            
            guard pass1OK, !isCancelled else {
                return NativeEncodeResult(
                    succeeded: false,
                    usedTwoPass: false,
                    pixelBufferPoolShared: isPoolShared,
                    errorMessage: isCancelled ? "Cancelled" : "Native VideoToolbox Pass 1 failed."
                )
            }
            
            var furtherPassesRequested: DarwinBoolean = false
            let endPassStatus = VTCompressionSessionEndPass(
                session,
                furtherPassesRequestedOut: &furtherPassesRequested,
                nil
            )
            guard endPassStatus == noErr, !isCancelled else {
                return NativeEncodeResult(
                    succeeded: false,
                    usedTwoPass: false,
                    pixelBufferPoolShared: isPoolShared,
                    errorMessage: "VTCompressionSessionEndPass failed (\(endPassStatus))."
                )
            }
            
            let finalFileType = Self.avFileType(for: options.targetContainer)
            if FileManager.default.fileExists(atPath: options.outputURL.path) {
                try? FileManager.default.removeItem(at: options.outputURL)
            }
            
            if furtherPassesRequested.boolValue {
                var timeRangePtr: UnsafePointer<CMTimeRange>?
                var timeRangeCount: CMItemCount = 0
                let trStatus = VTCompressionSessionGetTimeRangesForNextPass(
                    session,
                    timeRangeCountOut: &timeRangeCount,
                    timeRangeArrayOut: &timeRangePtr
                )
                var nextPassRanges: [CMTimeRange]? = nil
                if trStatus == noErr, timeRangeCount > 0, let timeRangePtr {
                    nextPassRanges = Array(UnsafeBufferPointer(start: timeRangePtr, count: timeRangeCount))
                }
                
                let matchedAVAudio = Self.matchingAVAudioTracks(avAudioTracks: avAudioTracks, selectedAudioTracks: selectedAudioTracks)
                let pass2OK = try await encodeVideoPass(
                    asset: asset,
                    sourceVideoTrack: sourceAVVideo,
                    session: session,
                    pixelFormat: pixelFormat,
                    destinationURL: options.outputURL,
                    container: options.targetContainer,
                    fastStart: options.fastStart,
                    audioTracks: matchedAVAudio,
                    stripMetadata: options.stripAllMetadata,
                    timeRanges: nextPassRanges,
                    totalDuration: totalDuration,
                    progressOffset: 0.5,
                    progressScale: 0.5,
                    speedPrefix: "Pass 2/2",
                    notice: notice,
                    isPoolShared: isPoolShared,
                    progressHandler: progressHandler
                )
                
                var ignoreMorePasses: DarwinBoolean = false
                _ = VTCompressionSessionEndPass(session, furtherPassesRequestedOut: &ignoreMorePasses, nil)
                
                guard pass2OK, !isCancelled else {
                    try? FileManager.default.removeItem(at: options.outputURL)
                    return NativeEncodeResult(
                        succeeded: false,
                        usedTwoPass: true,
                        pixelBufferPoolShared: isPoolShared,
                        errorMessage: isCancelled ? "Cancelled" : "Native VideoToolbox Pass 2 failed."
                    )
                }
            } else {
                // Single-pass satisfied encoder completely; copy encoded video + passthrough audio to final container
                let matchedAVAudio = Self.matchingAVAudioTracks(avAudioTracks: avAudioTracks, selectedAudioTracks: selectedAudioTracks)
                if matchedAVAudio.isEmpty {
                    try FileManager.default.moveItem(at: pass1URL, to: options.outputURL)
                } else {
                    try await muxPass1WithAudio(
                        pass1VideoURL: pass1URL,
                        sourceAudioTracks: matchedAVAudio,
                        outputURL: options.outputURL,
                        fileType: finalFileType,
                        fastStart: options.fastStart
                    )
                }
            }
            
            progressHandler(RemuxProgress(
                progress: 1.0,
                currentTime: totalDuration,
                totalTime: totalDuration,
                speed: "Done",
                activeSegments: 1,
                phaseLabel: nil,
                notice: notice,
                executionTierLabel: "Native 2-Pass HW",
                pixelBufferPoolShared: isPoolShared
            ))
            
            return NativeEncodeResult(
                succeeded: true,
                usedTwoPass: furtherPassesRequested.boolValue,
                pixelBufferPoolShared: isPoolShared
            )
        } catch {
            try? FileManager.default.removeItem(at: options.outputURL)
            return NativeEncodeResult(
                succeeded: false,
                usedTwoPass: false,
                pixelBufferPoolShared: false,
                errorMessage: error.localizedDescription
            )
        }
    }
    
    // MARK: - Private Pass Execution
    
    private func encodeVideoPass(
        asset: AVURLAsset,
        sourceVideoTrack: AVAssetTrack,
        session: VTCompressionSession,
        pixelFormat: OSType,
        destinationURL: URL,
        container: ContainerFormat,
        fastStart: Bool,
        audioTracks: [AVAssetTrack],
        stripMetadata: Bool,
        timeRanges: [CMTimeRange]?,
        totalDuration: Double,
        progressOffset: Double,
        progressScale: Double,
        speedPrefix: String,
        notice: String?,
        isPoolShared: Bool,
        progressHandler: @Sendable (RemuxProgress) -> Void
    ) async throws -> Bool {
        let beginStatus = VTCompressionSessionBeginPass(
            session,
            flags: timeRanges != nil ? .beginFinalPass : [],
            nil
        )
        guard beginStatus == noErr else { return false }
        
        let reader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: pixelFormat),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: sourceVideoTrack, outputSettings: readerSettings)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { return false }
        reader.add(videoOutput)
        
        var audioPairs: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        let fileType = Self.avFileType(for: container)
        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = fastStart
        if !stripMetadata {
            writer.metadata = (try? await asset.load(.metadata)) ?? []
        }
        
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        videoWriterInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoWriterInput) else { return false }
        writer.add(videoWriterInput)
        
        for audioTrack in audioTracks {
            let aOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            aOut.alwaysCopiesSampleData = false
            let formatDescs = (try? await audioTrack.load(.formatDescriptions)) ?? []
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formatDescs.first)
            aIn.expectsMediaDataInRealTime = false
            if reader.canAdd(aOut) && writer.canAdd(aIn) {
                reader.add(aOut)
                writer.add(aIn)
                audioPairs.append((aOut, aIn))
            }
        }
        
        guard reader.startReading() else { return false }
        guard writer.startWriting() else {
            reader.cancelReading()
            return false
        }
        writer.startSession(atSourceTime: .zero)
        
        let appendLock = NSLock()
        let writerState = LockedWriterState(writer: writer, input: videoWriterInput)
        let activeRanges = timeRanges
        
        let startClock = ContinuousClock.now
        var encodedFrameCount: Int64 = 0
        var lastEmit = ContinuousClock.now
        
        while !isCancelled, let sample = videoOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let frameDuration = CMSampleBufferGetDuration(sample)
            if let activeRanges, !activeRanges.contains(where: { $0.containsTime(pts) }) {
                continue
            }
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            
            while !videoWriterInput.isReadyForMoreMediaData && !isCancelled {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            if isCancelled { break }
            
            let encodeStatus = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: imageBuffer,
                presentationTimeStamp: pts,
                duration: frameDuration,
                frameProperties: nil,
                infoFlagsOut: nil
            ) { status, _, encodedSampleBuffer in
                guard status == noErr, let encodedSampleBuffer else {
                    if status != noErr {
                        appendLock.withLock { writerState.failed = true }
                    }
                    return
                }
                appendLock.withLock {
                    if writerState.input.isReadyForMoreMediaData {
                        if !writerState.input.append(encodedSampleBuffer) {
                            writerState.failed = true
                        }
                    } else {
                        while !writerState.input.isReadyForMoreMediaData && writerState.writer.status == .writing {
                            Thread.sleep(forTimeInterval: 0.002)
                        }
                        if writerState.writer.status == .writing && !writerState.input.append(encodedSampleBuffer) {
                            writerState.failed = true
                        }
                    }
                }
            }
            
            if encodeStatus != noErr || appendLock.withLock({ writerState.failed }) {
                reader.cancelReading()
                writer.cancelWriting()
                return false
            }
            
            encodedFrameCount += 1
            let now = ContinuousClock.now
            if now - lastEmit >= .milliseconds(120) {
                lastEmit = now
                let curSec = max(0, pts.seconds)
                let passFrac = min(1.0, max(0.0, curSec / totalDuration))
                let elapsed = max(0.01, Double((now - startClock).components.seconds) + Double((now - startClock).components.attoseconds) / 1e18)
                let speedMultiplier = curSec / elapsed
                progressHandler(RemuxProgress(
                    progress: progressOffset + passFrac * progressScale,
                    currentTime: curSec,
                    totalTime: totalDuration,
                    fps: Double(encodedFrameCount) / elapsed,
                    speed: String(format: "%@ • %.2fx", speedPrefix, max(0.01, speedMultiplier)),
                    bitrate: "",
                    frame: encodedFrameCount,
                    remainingSeconds: speedMultiplier > 0.01 ? max(0, (totalDuration - curSec) / speedMultiplier) : nil,
                    activeSegments: 1,
                    phaseLabel: "Native 2-Pass HW",
                    notice: notice,
                    executionTierLabel: "Native 2-Pass HW",
                    pixelBufferPoolShared: isPoolShared
                ))
            }
        }
        
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        videoWriterInput.markAsFinished()
        
        if !isCancelled {
            for pair in audioPairs {
                while !isCancelled, let audioSample = pair.output.copyNextSampleBuffer() {
                    while !pair.input.isReadyForMoreMediaData && !isCancelled {
                        try await Task.sleep(nanoseconds: 2_000_000)
                    }
                    if isCancelled { break }
                    pair.input.append(audioSample)
                }
                pair.input.markAsFinished()
            }
        }
        
        if isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            return false
        }
        
        await writer.finishWriting()
        return writer.status == .completed && !appendLock.withLock({ writerState.failed })
    }
    
    private func muxPass1WithAudio(
        pass1VideoURL: URL,
        sourceAudioTracks: [AVAssetTrack],
        outputURL: URL,
        fileType: AVFileType,
        fastStart: Bool
    ) async throws {
        let videoAsset = AVURLAsset(url: pass1VideoURL)
        let vTracks = try await videoAsset.loadTracks(withMediaType: .video)
        guard let vTrack = vTracks.first else {
            try FileManager.default.moveItem(at: pass1VideoURL, to: outputURL)
            return
        }
        let vReader = try AVAssetReader(asset: videoAsset)
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        vReader.add(vOut)
        
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = fastStart
        let vFmt = (try? await vTrack.load(.formatDescriptions)) ?? []
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vFmt.first)
        writer.add(vIn)
        
        var audioReaders: [(reader: AVAssetReader, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        for aTrack in sourceAudioTracks {
            if let asset = aTrack.asset {
                let aReader = try AVAssetReader(asset: asset)
                let aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
                let aFmt = (try? await aTrack.load(.formatDescriptions)) ?? []
                let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: aFmt.first)
                if aReader.canAdd(aOut) && writer.canAdd(aIn) {
                    aReader.add(aOut)
                    writer.add(aIn)
                    audioReaders.append((aReader, aOut, aIn))
                }
            }
        }
        
        vReader.startReading()
        for entry in audioReaders { entry.reader.startReading() }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        while let s = vOut.copyNextSampleBuffer() {
            while !vIn.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            vIn.append(s)
        }
        vIn.markAsFinished()
        
        for entry in audioReaders {
            while let s = entry.output.copyNextSampleBuffer() {
                while !entry.input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                entry.input.append(s)
            }
            entry.input.markAsFinished()
        }
        await writer.finishWriting()
    }
    
    private static func avFileType(for container: ContainerFormat) -> AVFileType {
        switch container {
        case .mov: return .mov
        case .m4v: return .m4v
        default: return .mp4
        }
    }
    
    private static func matchingAVAudioTracks(
        avAudioTracks: [AVAssetTrack],
        selectedAudioTracks: [MediaTrack]
    ) -> [AVAssetTrack] {
        guard !selectedAudioTracks.isEmpty else { return [] }
        return avAudioTracks.enumerated().compactMap { idx, avTrack in
            if idx < selectedAudioTracks.count {
                return avTrack
            }
            return nil
        }
    }
    
    private static func resolveProfileLevel(
        for action: TrackAction,
        config: VideoEncodingConfig,
        isTenBit: Bool
    ) -> CFString? {
        let p = config.profile?.lowercased()
        switch action {
        case .transcodeHEVC_VT:
            switch p {
            case "main": return kVTProfileLevel_HEVC_Main_AutoLevel
            case "main10": return kVTProfileLevel_HEVC_Main10_AutoLevel
            case "main42210": return kVTProfileLevel_HEVC_Main42210_AutoLevel
            default:
                return isTenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
            }
        case .transcodeH264_VT:
            switch p {
            case "baseline", "constrained_baseline": return kVTProfileLevel_H264_Baseline_AutoLevel
            case "main": return kVTProfileLevel_H264_Main_AutoLevel
            case "high", "constrained_high": return kVTProfileLevel_H264_High_AutoLevel
            default: return kVTProfileLevel_H264_High_AutoLevel
            }
        default:
            return nil
        }
    }
    
    private static func applyColorProperties(
        to session: VTCompressionSession,
        track: MediaTrack,
        config: VideoEncodingConfig
    ) {
        let effectiveCS = config.colorSpace ?? .auto
        let primaries = (effectiveCS == .auto ? track.colorPrimaries : effectiveCS.ffPrimaries)?.lowercased()
        let transfer = (effectiveCS == .auto ? track.colorTransfer : effectiveCS.ffTransfer)?.lowercased()
        let matrix = (effectiveCS == .auto ? track.colorSpace : effectiveCS.ffMatrix)?.lowercased()
        
        if let primaries {
            switch primaries {
            case "bt709":
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
            case "bt2020":
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_2020)
            case "smpte170m":
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_SMPTE_C)
            default:
                break
            }
        }
        if let transfer {
            switch transfer {
            case "bt709", "bt2020-10", "bt2020-12":
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
            case "arib-std-b67":
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_2100_HLG)
            case "smpte2084":
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
            default:
                break
            }
        }
        if let matrix {
            switch matrix {
            case "bt709":
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            case "bt2020nc", "bt2020c":
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_2020)
            case "smpte170m":
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
            default:
                break
            }
        }
    }
}

private final class LockedWriterState: @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var failed: Bool = false
    
    init(writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.writer = writer
        self.input = input
    }
}
