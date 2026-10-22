import Foundation

public enum ExtractionDestinationType: String, CaseIterable, Identifiable {
    case sourceDirectory = "sourceDirectory"
    case customDirectory = "customDirectory"
    case alwaysAsk = "alwaysAsk"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .sourceDirectory: return "Same folder as source video"
        case .customDirectory: return "Custom output folder"
        case .alwaysAsk: return "Always ask for destination"
        }
    }
}

public enum NamingPatternHelper {
    public static let defaultPattern = "{filename}.{title}.{ext}"
    
    public static let presetPatterns: [String] = [
        "{filename}.{title}.{ext}",
        "{filename}_track{index}_{lang}.{ext}",
        "{filename} - {codec} ({lang}).{ext}",
        "{filename}_{title}_{codec}.{ext}",
        "{filename}.{ext}"
    ]
    
    public static func formatFilename(
        pattern: String,
        sourceFilename: String,
        track: MediaTrack,
        targetExtension: String
    ) -> String {
        let baseName = (sourceFilename as NSString).deletingPathExtension
        let titleSafe = track.title.isEmpty ? (track.language == "und" ? "track\(track.streamIndex)" : track.language) : track.title
        let lang = track.language.isEmpty ? "und" : track.language
        let codec: String
        if track.action.isTranscode {
            switch track.action {
            case .transcodeH264_VT: codec = "h264"
            case .transcodeHEVC_VT: codec = "hevc"
            case .transcodeProRes: codec = "prores"
            case .transcodeALAC: codec = "alac"
            case .transcodeFLAC: codec = "flac"
            case .transcodeMP3: codec = "mp3"
            case .transcodeOpus: codec = "opus"
            case .transcodeAAC_Stereo, .transcodeAAC_51: codec = "aac"
            case .transcodeAC3_51: codec = "ac3"
            case .transcodeEAC3_51: codec = "eac3"
            case .transcodeWAV: codec = "wav"
            case .transcodeAIFF: codec = "aiff"
            case .transcodeSRT: codec = "srt"
            case .transcodeMovText: codec = "mov_text"
            default: codec = track.codecName
            }
        } else {
            codec = track.codecName
        }
        let indexStr = "\(track.streamIndex)"
        let channelsStr = track.channels == 1 ? "mono" : (track.channels == 6 ? "5.1" : (track.channels == 8 ? "7.1" : "stereo"))
        
        var result = pattern.isEmpty ? defaultPattern : pattern
        result = result.replacingOccurrences(of: "{filename}", with: baseName)
        result = result.replacingOccurrences(of: "{title}", with: sanitizeFilename(titleSafe))
        result = result.replacingOccurrences(of: "{lang}", with: sanitizeFilename(lang))
        result = result.replacingOccurrences(of: "{codec}", with: sanitizeFilename(codec))
        result = result.replacingOccurrences(of: "{index}", with: indexStr)
        result = result.replacingOccurrences(of: "{channels}", with: channelsStr)
        result = result.replacingOccurrences(of: "{ext}", with: targetExtension)
        
        // Ensure ends with .extension
        if !result.lowercased().hasSuffix(".\(targetExtension.lowercased())") {
            result += ".\(targetExtension)"
        }
        
        return result
    }
    
    public static func sanitizeFilename(_ string: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        return string.components(separatedBy: invalidCharacters).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
