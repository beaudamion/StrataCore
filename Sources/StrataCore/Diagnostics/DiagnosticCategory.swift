import Foundation

/// Functional subsystem category for diagnostic events and error tracking.
public enum DiagnosticCategory: String, Sendable, Codable, CaseIterable {
    case probe
    case remux
    case transcode
    case batch
    case ffmpegLocator
    case videoToolbox
    case smartCut
    case system
}
