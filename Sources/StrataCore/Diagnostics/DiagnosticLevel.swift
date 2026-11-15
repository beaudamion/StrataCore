import Foundation

/// Severity level for engine and application diagnostic events.
public enum DiagnosticLevel: String, Sendable, Codable, CaseIterable {
    case debug
    case info
    case warning
    case error
}
