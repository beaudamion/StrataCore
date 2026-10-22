import Foundation
import SwiftUI

public enum BatchStatus: Hashable {
    case pending
    case probing
    case ready
    case processing(progress: Double, speed: String)
    case completed(elapsedTime: TimeInterval)
    case failed(message: String)
    
    public var displayText: String {
        switch self {
        case .pending: return "Pending"
        case .probing: return "Probing..."
        case .ready: return "Ready"
        case .processing(let progress, let speed):
            let pct = Int(progress * 100)
            return "\(pct)% (\(speed))"
        case .completed: return "Completed"
        case .failed(let message): return "Failed: \(message)"
        }
    }
    
    public var iconName: String {
        switch self {
        case .pending: return "clock"
        case .probing: return "magnifyingglass"
        case .ready: return "checkmark.circle"
        case .processing: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
    
    public var tintColor: Color {
        switch self {
        case .pending: return .secondary
        case .probing: return .blue
        case .ready: return .teal
        case .processing: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}

public enum BatchAudioPreset: String, CaseIterable, Identifiable, Codable {
    case passthrough = "Passthrough"
    case transcodeNonAAC = "Transcode Non-AAC to AAC"
    case alwaysAACStereo = "Convert All to AAC Stereo"
    case alwaysAAC51 = "Convert All to AAC 5.1"
    
    public var id: String { rawValue }
}

public enum BatchSubtitlePreset: String, CaseIterable, Identifiable, Codable {
    case keepAll = "Keep All Subtitles"
    case keepFirst = "Keep First Subtitle Only"
    case stripAll = "Strip All Subtitles"
    
    public var id: String { rawValue }
}

public struct BatchItem: Identifiable, Hashable {
    public let id: UUID
    public var sourceURL: URL
    public var mediaFile: MediaFile?
    public var targetContainer: ContainerFormat
    public var outputURL: URL?
    public var stripMetadata: Bool
    public var fastStart: Bool
    public var isCustomSingleItem: Bool
    public var audioPreset: BatchAudioPreset
    public var subtitlePreset: BatchSubtitlePreset
    public var status: BatchStatus
    public var progress: Double
    public var speed: String
    public var errorMessage: String?
    
    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        mediaFile: MediaFile? = nil,
        targetContainer: ContainerFormat = .mp4,
        outputURL: URL? = nil,
        stripMetadata: Bool = true,
        fastStart: Bool = true,
        isCustomSingleItem: Bool = false,
        audioPreset: BatchAudioPreset = .passthrough,
        subtitlePreset: BatchSubtitlePreset = .keepAll,
        status: BatchStatus = .pending,
        progress: Double = 0.0,
        speed: String = "",
        errorMessage: String? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.mediaFile = mediaFile
        self.targetContainer = targetContainer
        self.outputURL = outputURL
        self.stripMetadata = stripMetadata
        self.fastStart = fastStart
        self.isCustomSingleItem = isCustomSingleItem
        self.audioPreset = audioPreset
        self.subtitlePreset = subtitlePreset
        self.status = status
        self.progress = progress
        self.speed = speed
        self.errorMessage = errorMessage
    }
    
    public var isProcessing: Bool {
        if case .processing = status { return true }
        return false
    }
    
    public var filename: String {
        sourceURL.lastPathComponent
    }
    
    public var outputFilename: String {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        return "\(baseName).\(targetContainer.fileExtension)"
    }
}
