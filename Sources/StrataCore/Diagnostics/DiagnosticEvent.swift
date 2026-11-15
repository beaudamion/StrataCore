import Foundation

/// Discrete diagnostic event emitted during media analysis, remuxing, or transcoding.
public struct DiagnosticEvent: Identifiable, Sendable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let category: DiagnosticCategory
    public let level: DiagnosticLevel
    public let message: String
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: DiagnosticCategory,
        level: DiagnosticLevel,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
        self.metadata = metadata
    }
}
