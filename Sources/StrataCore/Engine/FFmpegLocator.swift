import Foundation

public enum FFmpegSource: String, CaseIterable, Codable {
    case bundled = "Bundled Engine"
    case homebrew = "Homebrew"
    case custom = "Custom Path"
    case system = "System / PATH"
    case missing = "Missing"
}

public enum FFmpegEngineMode: String, CaseIterable, Identifiable, Codable {
    case auto = "Auto-Detect"
    case bundled = "Bundled Engine"
    case homebrew = "Homebrew"
    case custom = "Custom Path"
    
    public var id: String { rawValue }
    
    public var iconName: String {
        switch self {
        case .auto: return "sparkles"
        case .bundled: return "shippingbox.fill"
        case .homebrew: return "mug.fill"
        case .custom: return "folder.badge.gearshape"
        }
    }
}

public final class FFmpegLocator: ObservableObject {
    public static let shared = FFmpegLocator()
    
    @Published public private(set) var selectedMode: FFmpegEngineMode = .auto
    @Published public private(set) var ffmpegPath: String?
    @Published public private(set) var ffprobePath: String?
    @Published public private(set) var ffmpegVersion: String?
    @Published public private(set) var activeSource: FFmpegSource = .missing
    @Published public private(set) var isReady: Bool = false
    
    private var versionCache: [String: String] = [:]
    
    private let engineModeKey = "ffmpeg_engine_mode"
    private let customFFmpegKey = "custom_ffmpeg_path"
    private let customFFprobeKey = "custom_ffprobe_path"
    
    public init() {
        let saved = UserDefaults.standard.string(forKey: engineModeKey)
        self.selectedMode = saved.flatMap { FFmpegEngineMode(rawValue: $0) } ?? .auto
        refresh()
    }
    
    public var brewPath: String? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: "/opt/homebrew/bin/brew") {
            return "/opt/homebrew/bin/brew"
        }
        if fm.isExecutableFile(atPath: "/usr/local/bin/brew") {
            return "/usr/local/bin/brew"
        }
        return nil
    }
    
    public var isHomebrewAvailable: Bool {
        brewPath != nil
    }
    
    public func setEngineMode(_ mode: FFmpegEngineMode) {
        self.selectedMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: engineModeKey)
        refresh()
    }
    
    public func refresh() {
        let (ffmpeg, source) = findBinaryForCurrentMode(named: "ffmpeg", customKey: customFFmpegKey)
        let (ffprobe, _) = findBinaryForCurrentMode(named: "ffprobe", customKey: customFFprobeKey)
        
        self.ffmpegPath = ffmpeg
        self.ffprobePath = ffprobe
        self.isReady = (ffmpeg != nil && ffprobe != nil)
        self.activeSource = (ffmpeg != nil && ffprobe != nil) ? source : .missing
        
        if let ffmpeg = ffmpeg {
            if let cached = versionCache[ffmpeg] {
                self.ffmpegVersion = cached
            } else if let queried = queryVersion(binaryPath: ffmpeg) {
                self.versionCache[ffmpeg] = queried
                self.ffmpegVersion = queried
            } else {
                self.ffmpegVersion = nil
            }
        } else {
            self.ffmpegVersion = nil
        }
    }
    
    public func setCustomPaths(ffmpeg: String?, ffprobe: String?) {
        let defaults = UserDefaults.standard
        if let ffmpeg = ffmpeg, !ffmpeg.isEmpty {
            defaults.set(ffmpeg, forKey: customFFmpegKey)
        } else {
            defaults.removeObject(forKey: customFFmpegKey)
        }
        
        if let ffprobe = ffprobe, !ffprobe.isEmpty {
            defaults.set(ffprobe, forKey: customFFprobeKey)
        } else {
            defaults.removeObject(forKey: customFFprobeKey)
        }
        
        // If user actively sets custom paths, switch mode to custom
        self.selectedMode = .custom
        defaults.set(FFmpegEngineMode.custom.rawValue, forKey: engineModeKey)
        refresh()
    }
    
    public func resetCustomPaths() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: customFFmpegKey)
        defaults.removeObject(forKey: customFFprobeKey)
        setEngineMode(.auto)
    }
    
    private func findBinaryForCurrentMode(named name: String, customKey: String) -> (String?, FFmpegSource) {
        switch selectedMode {
        case .bundled:
            if let path = findBundledBinary(named: name) {
                return (path, .bundled)
            }
            return (nil, .missing)
            
        case .homebrew:
            if let path = findHomebrewBinary(named: name) {
                return (path, .homebrew)
            }
            return (nil, .missing)
            
        case .custom:
            if let custom = UserDefaults.standard.string(forKey: customKey),
               FileManager.default.isExecutableFile(atPath: custom) {
                return (custom, .custom)
            }
            return (nil, .missing)
            
        case .auto:
            // Priority 1: Bundled Engine
            if let bundled = findBundledBinary(named: name) {
                return (bundled, .bundled)
            }
            // Priority 2: Homebrew
            if let brew = findHomebrewBinary(named: name) {
                return (brew, .homebrew)
            }
            // Priority 3: System PATH
            if let sys = findSystemBinary(named: name) {
                return (sys.0, sys.1)
            }
            return (nil, .missing)
        }
    }
    
    private func findBundledBinary(named name: String) -> String? {
        let fm = FileManager.default
        
        // 1. App Bundle Resources (Strata.app/Contents/Resources/bin/name or Resources/name)
        if let resourceURL = Bundle.main.resourceURL {
            let inBin = resourceURL.appendingPathComponent("bin").appendingPathComponent(name).path
            if fm.isExecutableFile(atPath: inBin) { return inBin }
            let direct = resourceURL.appendingPathComponent(name).path
            if fm.isExecutableFile(atPath: direct) { return direct }
        }
        
        // 2. Executable parent directory Resources
        let execDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let localBin = execDir.appendingPathComponent("Resources/bin").appendingPathComponent(name).path
        if fm.isExecutableFile(atPath: localBin) { return localBin }
        
        // 3. Project working directory (during development)
        let projectBin = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("Sources/Strata/Resources/bin")
            .appendingPathComponent(name).path
        if fm.isExecutableFile(atPath: projectBin) { return projectBin }
        
        return nil
    }
    
    private func findHomebrewBinary(named name: String) -> String? {
        let fm = FileManager.default
        let brewArm = "/opt/homebrew/bin/\(name)"
        if fm.isExecutableFile(atPath: brewArm) { return brewArm }
        let brewIntel = "/usr/local/bin/\(name)"
        if fm.isExecutableFile(atPath: brewIntel) { return brewIntel }
        return nil
    }
    
    private func findSystemBinary(named name: String) -> (String, FFmpegSource)? {
        let fm = FileManager.default
        let usrBin = "/usr/bin/\(name)"
        if fm.isExecutableFile(atPath: usrBin) { return (usrBin, .system) }
        
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.components(separatedBy: ":") {
                let candidate = (dir as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: candidate) {
                    let src: FFmpegSource = candidate.contains("homebrew") ? .homebrew : .system
                    return (candidate, src)
                }
            }
        }
        return nil
    }
    
    private func queryVersion(binaryPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["-version"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let firstLine = output.components(separatedBy: .newlines).first ?? ""
                return firstLine
            }
        } catch {
            return nil
        }
        return nil
    }
}
