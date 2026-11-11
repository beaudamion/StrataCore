import Foundation

public struct RemuxOptions: Codable, Hashable, Sendable {
    public var targetContainer: ContainerFormat
    public var outputURL: URL
    public var stripAllMetadata: Bool
    public var stripChapters: Bool
    public var fastStart: Bool
    public var useHardwareAcceleration: Bool
    public var segmentedEncodingMode: SegmentedEncodingMode
    public var minSegmentationDuration: Double
    
    public init(
        targetContainer: ContainerFormat = .mp4,
        outputURL: URL,
        stripAllMetadata: Bool = true,
        stripChapters: Bool = false,
        fastStart: Bool = true,
        useHardwareAcceleration: Bool = true,
        segmentedEncodingMode: SegmentedEncodingMode = .auto,
        minSegmentationDuration: Double = 30.0
    ) {
        self.targetContainer = targetContainer
        self.outputURL = outputURL
        self.stripAllMetadata = stripAllMetadata
        self.stripChapters = stripChapters
        self.fastStart = fastStart
        self.useHardwareAcceleration = useHardwareAcceleration
        self.segmentedEncodingMode = segmentedEncodingMode
        self.minSegmentationDuration = minSegmentationDuration
    }
}
