import Foundation

public struct FFmpegBinaryCapabilities: Equatable, Sendable {
    public let supportsVideoToolboxVLD: Bool
    public let h264VTSupportsSpatialAQ: Bool
    public let hevcVTSupportsSpatialAQ: Bool
    public let h264VTSupportsRealtime: Bool
    public let hevcVTSupportsRealtime: Bool
    public let proResVTSupportsVendor: Bool
    public let proResKsSupportsVendor: Bool
    public let supportsScaleVT: Bool
    public let supportsTransposeVT: Bool
    public let supportsYadifVT: Bool
    public let supportsAudioToolboxAAC: Bool
    public let supportsLoudnorm: Bool
    public let supportsXPSNR: Bool
    public let supportsLibVMAF: Bool
    public let supportsDumpExtraBSF: Bool
    public let supportsProResRAWDecode: Bool
    
    public init(
        supportsVideoToolboxVLD: Bool = true,
        h264VTSupportsSpatialAQ: Bool = true,
        hevcVTSupportsSpatialAQ: Bool = true,
        h264VTSupportsRealtime: Bool = true,
        hevcVTSupportsRealtime: Bool = true,
        proResVTSupportsVendor: Bool = false,
        proResKsSupportsVendor: Bool = true,
        supportsScaleVT: Bool = true,
        supportsTransposeVT: Bool = true,
        supportsYadifVT: Bool = true,
        supportsAudioToolboxAAC: Bool = true,
        supportsLoudnorm: Bool = true,
        supportsXPSNR: Bool = true,
        supportsLibVMAF: Bool = true,
        supportsDumpExtraBSF: Bool = true,
        supportsProResRAWDecode: Bool = true
    ) {
        self.supportsVideoToolboxVLD = supportsVideoToolboxVLD
        self.h264VTSupportsSpatialAQ = h264VTSupportsSpatialAQ
        self.hevcVTSupportsSpatialAQ = hevcVTSupportsSpatialAQ
        self.h264VTSupportsRealtime = h264VTSupportsRealtime
        self.hevcVTSupportsRealtime = hevcVTSupportsRealtime
        self.proResVTSupportsVendor = proResVTSupportsVendor
        self.proResKsSupportsVendor = proResKsSupportsVendor
        self.supportsScaleVT = supportsScaleVT
        self.supportsTransposeVT = supportsTransposeVT
        self.supportsYadifVT = supportsYadifVT
        self.supportsAudioToolboxAAC = supportsAudioToolboxAAC
        self.supportsLoudnorm = supportsLoudnorm
        self.supportsXPSNR = supportsXPSNR
        self.supportsLibVMAF = supportsLibVMAF
        self.supportsDumpExtraBSF = supportsDumpExtraBSF
        self.supportsProResRAWDecode = supportsProResRAWDecode
    }
    
    /// Deterministic baseline matching Apple Silicon FFmpeg 9.0.2 with VideoToolbox & AudioToolbox.
    public static let assumedModernDefaults = FFmpegBinaryCapabilities()
    
    public static func parse(
        pixFmtsOutput: String,
        filtersOutput: String,
        bsfsOutput: String,
        encodersOutput: String,
        decodersOutput: String,
        h264VTHelp: String,
        hevcVTHelp: String,
        proResVTHelp: String,
        proResKsHelp: String
    ) -> FFmpegBinaryCapabilities {
        let supportsVLD = pixFmtsOutput.contains("videotoolbox_vld")
            || h264VTHelp.contains("videotoolbox_vld")
            || hevcVTHelp.contains("videotoolbox_vld")
        
        return FFmpegBinaryCapabilities(
            supportsVideoToolboxVLD: supportsVLD,
            h264VTSupportsSpatialAQ: h264VTHelp.contains("-spatial_aq"),
            hevcVTSupportsSpatialAQ: hevcVTHelp.contains("-spatial_aq"),
            h264VTSupportsRealtime: h264VTHelp.contains("-realtime"),
            hevcVTSupportsRealtime: hevcVTHelp.contains("-realtime"),
            proResVTSupportsVendor: proResVTHelp.contains("-vendor"),
            proResKsSupportsVendor: proResKsHelp.contains("-vendor") || proResKsHelp.isEmpty,
            supportsScaleVT: filtersOutput.contains("scale_vt"),
            supportsTransposeVT: filtersOutput.contains("transpose_vt"),
            supportsYadifVT: filtersOutput.contains("yadif_videotoolbox"),
            supportsAudioToolboxAAC: encodersOutput.contains("aac_at"),
            supportsLoudnorm: filtersOutput.contains("loudnorm"),
            supportsXPSNR: filtersOutput.contains("xpsnr"),
            supportsLibVMAF: filtersOutput.contains("libvmaf"),
            supportsDumpExtraBSF: bsfsOutput.contains("dump_extra"),
            supportsProResRAWDecode: decodersOutput.contains("prores_raw")
        )
    }
}

public actor BinaryCapabilityProbe {
    public static let shared = BinaryCapabilityProbe()
    
    private struct CachedEntry {
        let modificationDate: Date?
        let fileSize: UInt64?
        let capabilities: FFmpegBinaryCapabilities
    }
    
    private var cache: [String: CachedEntry] = [:]
    
    public init() {}
    
    public func capabilities(for ffmpegPath: String?) async -> FFmpegBinaryCapabilities {
        guard let ffmpegPath,
              !ffmpegPath.isEmpty,
              FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
            return .assumedModernDefaults
        }
        
        let attrs = try? FileManager.default.attributesOfItem(atPath: ffmpegPath)
        let modDate = attrs?[.modificationDate] as? Date
        let size = attrs?[.size] as? UInt64
        
        if let existing = cache[ffmpegPath],
           existing.modificationDate == modDate,
           existing.fileSize == size {
            return existing.capabilities
        }
        
        let probed = await probeLiveBinary(at: ffmpegPath)
        cache[ffmpegPath] = CachedEntry(modificationDate: modDate, fileSize: size, capabilities: probed)
        return probed
    }
    
    public func clearCache() {
        cache.removeAll()
    }
    
    private func probeLiveBinary(at path: String) async -> FFmpegBinaryCapabilities {
        async let pixFmts = runQuery(ffmpegPath: path, args: ["-hide_banner", "-pix_fmts"])
        async let filters = runQuery(ffmpegPath: path, args: ["-hide_banner", "-filters"])
        async let bsfs = runQuery(ffmpegPath: path, args: ["-hide_banner", "-bsfs"])
        async let encoders = runQuery(ffmpegPath: path, args: ["-hide_banner", "-encoders"])
        async let decoders = runQuery(ffmpegPath: path, args: ["-hide_banner", "-decoders"])
        async let h264VT = runQuery(ffmpegPath: path, args: ["-hide_banner", "-h", "encoder=h264_videotoolbox"])
        async let hevcVT = runQuery(ffmpegPath: path, args: ["-hide_banner", "-h", "encoder=hevc_videotoolbox"])
        async let proResVT = runQuery(ffmpegPath: path, args: ["-hide_banner", "-h", "encoder=prores_videotoolbox"])
        async let proResKs = runQuery(ffmpegPath: path, args: ["-hide_banner", "-h", "encoder=prores_ks"])
        
        return await FFmpegBinaryCapabilities.parse(
            pixFmtsOutput: pixFmts,
            filtersOutput: filters,
            bsfsOutput: bsfs,
            encodersOutput: encoders,
            decodersOutput: decoders,
            h264VTHelp: h264VT,
            hevcVTHelp: hevcVT,
            proResVTHelp: proResVT,
            proResKsHelp: proResKs
        )
    }
    
    private func runQuery(ffmpegPath: String, args: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: ffmpegPath)
                proc.arguments = args
                let outPipe = Pipe()
                proc.standardInput = FileHandle.nullDevice
                proc.standardOutput = outPipe
                proc.standardError = FileHandle.nullDevice
                
                do {
                    try proc.run()
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}
