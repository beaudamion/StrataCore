import Foundation

/// Captured snapshot of a failed FFmpeg subprocess, ffprobe inspection, or Native VideoToolbox session.
public struct FailedJobSnapshot: Identifiable, Sendable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let operation: String
    public let executableName: String
    public let arguments: [String]
    public let exitCode: Int32
    public let stderrTail: [String]
    public let probeSummary: String?
    public let osStatusError: Int32?
    public let technicalDetails: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        operation: String,
        executableName: String,
        arguments: [String],
        exitCode: Int32,
        stderrTail: [String],
        probeSummary: String? = nil,
        osStatusError: Int32? = nil,
        technicalDetails: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.operation = operation
        self.executableName = executableName
        self.arguments = arguments
        self.exitCode = exitCode
        self.stderrTail = stderrTail
        self.probeSummary = probeSummary
        self.osStatusError = osStatusError
        self.technicalDetails = technicalDetails
    }
}
