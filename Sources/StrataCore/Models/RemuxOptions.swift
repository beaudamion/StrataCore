import Foundation

public struct MediaTrimRange: Hashable, Codable, Sendable {
    public var inTime: Double
    public var outTime: Double
    
    public init(inTime: Double, outTime: Double) {
        let clampedIn = max(0, inTime)
        let clampedOut = max(clampedIn, outTime)
        self.inTime = clampedIn
        self.outTime = clampedOut
    }
    
    public var duration: Double {
        max(0, outTime - inTime)
    }
    
    public var isValid: Bool {
        duration > 0.01
    }
}

public enum PerceptualQCMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case none = "none"
    case xpsnr = "xpsnr"
    case libvmaf = "libvmaf"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .none: return "Off"
        case .xpsnr: return "XPSNR (Fast Perceptual PSNR)"
        case .libvmaf: return "libvmaf (Netflix VMAF)"
        }
    }
    
    public var shortLabel: String {
        switch self {
        case .none: return "Off"
        case .xpsnr: return "XPSNR"
        case .libvmaf: return "libvmaf"
        }
    }
    
    public func displayName(showTechnicalDetails: Bool) -> String {
        if showTechnicalDetails {
            return displayName
        }
        switch self {
        case .none: return "Off"
        case .xpsnr: return "Fast Quality Score"
        case .libvmaf: return "Detailed Quality Score"
        }
    }
    
    public func shortLabel(showTechnicalDetails: Bool) -> String {
        if showTechnicalDetails {
            return shortLabel
        }
        switch self {
        case .none: return "Off"
        case .xpsnr: return "Fast QC"
        case .libvmaf: return "Detailed QC"
        }
    }
}

public struct RemuxOptions: Codable, Hashable, Sendable {
    public var targetContainer: ContainerFormat
    public var outputURL: URL
    public var stripAllMetadata: Bool
    public var stripChapters: Bool
    public var fastStart: Bool
    public var useHardwareAcceleration: Bool
    public var segmentedEncodingMode: SegmentedEncodingMode
    public var minSegmentationDuration: Double
    public var trimRange: MediaTrimRange?
    public var perceptualQCMetric: PerceptualQCMetric
    public var preferSoftwareTwoPass: Bool
    public var allowDolbyVisionReencode: Bool
    
    public init(
        targetContainer: ContainerFormat = .mp4,
        outputURL: URL,
        stripAllMetadata: Bool = true,
        stripChapters: Bool = false,
        fastStart: Bool = true,
        useHardwareAcceleration: Bool = true,
        segmentedEncodingMode: SegmentedEncodingMode = .auto,
        minSegmentationDuration: Double = 30.0,
        trimRange: MediaTrimRange? = nil,
        perceptualQCMetric: PerceptualQCMetric = .none,
        preferSoftwareTwoPass: Bool = false,
        allowDolbyVisionReencode: Bool = false
    ) {
        self.targetContainer = targetContainer
        self.outputURL = outputURL
        self.stripAllMetadata = stripAllMetadata
        self.stripChapters = stripChapters
        self.fastStart = fastStart
        self.useHardwareAcceleration = useHardwareAcceleration
        self.segmentedEncodingMode = segmentedEncodingMode
        self.minSegmentationDuration = minSegmentationDuration
        self.trimRange = trimRange
        self.perceptualQCMetric = perceptualQCMetric
        self.preferSoftwareTwoPass = preferSoftwareTwoPass
        self.allowDolbyVisionReencode = allowDolbyVisionReencode
    }
}
