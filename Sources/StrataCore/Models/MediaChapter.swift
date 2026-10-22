import Foundation

public struct MediaChapter: Identifiable, Hashable, Codable {
    public let id: Int
    public let startTime: Double
    public let endTime: Double
    public let title: String
    
    public init(id: Int, startTime: Double, endTime: Double, title: String) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.title = title
    }
}
