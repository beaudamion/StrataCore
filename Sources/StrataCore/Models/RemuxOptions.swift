import Foundation

public struct RemuxOptions: Codable, Hashable {
    public var targetContainer: ContainerFormat
    public var outputURL: URL
    public var stripAllMetadata: Bool
    public var stripChapters: Bool
    public var fastStart: Bool
    public var useHardwareAcceleration: Bool
    
    public init(
        targetContainer: ContainerFormat = .mp4,
        outputURL: URL,
        stripAllMetadata: Bool = true,
        stripChapters: Bool = false,
        fastStart: Bool = true,
        useHardwareAcceleration: Bool = true
    ) {
        self.targetContainer = targetContainer
        self.outputURL = outputURL
        self.stripAllMetadata = stripAllMetadata
        self.stripChapters = stripChapters
        self.fastStart = fastStart
        self.useHardwareAcceleration = useHardwareAcceleration
    }
}
