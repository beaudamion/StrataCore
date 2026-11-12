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
    
    private enum CachedProbeResult {
        case valid(signature: String, version: String)
        case invalid(signature: String)
    }
    
    private var probeCache: [String: CachedProbeResult] = [:]
    private let probeCacheLock = NSLock()
    
    private let userDefaults: UserDefaults
    private let bundledSearchPathsOverride: [String: [String]]?
    private let homebrewSearchDirsOverride: [String]?
    private let systemSearchDirsOverride: [String]?
    
    private let engineModeKey = "ffmpeg_engine_mode"
    private let customFFmpegKey = "custom_ffmpeg_path"
    private let customFFprobeKey = "custom_ffprobe_path"
    
    public convenience init() {
        self.init(
            userDefaults: .standard,
            bundledSearchPathsOverride: nil,
            homebrewSearchDirsOverride: nil,
            systemSearchDirsOverride: nil
        )
    }
    
    internal init(
        userDefaults: UserDefaults,
        bundledSearchPathsOverride: [String: [String]]? = nil,
        homebrewSearchDirsOverride: [String]? = nil,
        systemSearchDirsOverride: [String]? = nil
    ) {
        self.userDefaults = userDefaults
        self.bundledSearchPathsOverride = bundledSearchPathsOverride
        self.homebrewSearchDirsOverride = homebrewSearchDirsOverride
        self.systemSearchDirsOverride = systemSearchDirsOverride
        let saved = userDefaults.string(forKey: engineModeKey)
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
        userDefaults.set(mode.rawValue, forKey: engineModeKey)
        refresh()
    }
    
    public func refresh() {
        let (ffmpeg, ffprobe, source) = resolveBinariesForCurrentMode()
        
        self.ffmpegPath = ffmpeg
        self.ffprobePath = ffprobe
        self.isReady = (ffmpeg != nil && ffprobe != nil)
        self.activeSource = (ffmpeg != nil && ffprobe != nil) ? source : .missing
        
        if let ffmpeg = ffmpeg, let ver = verifiedVersion(binaryPath: ffmpeg) {
            self.ffmpegVersion = ver
        } else {
            self.ffmpegVersion = nil
        }
    }
    
    public func setCustomPaths(ffmpeg: String?, ffprobe: String?) {
        if let ffmpeg = ffmpeg, !ffmpeg.isEmpty {
            userDefaults.set(ffmpeg, forKey: customFFmpegKey)
        } else {
            userDefaults.removeObject(forKey: customFFmpegKey)
        }
        
        if let ffprobe = ffprobe, !ffprobe.isEmpty {
            userDefaults.set(ffprobe, forKey: customFFprobeKey)
        } else {
            userDefaults.removeObject(forKey: customFFprobeKey)
        }
        
        // If user actively sets custom paths, switch mode to custom
        self.selectedMode = .custom
        userDefaults.set(FFmpegEngineMode.custom.rawValue, forKey: engineModeKey)
        refresh()
    }
    
    public func resetCustomPaths() {
        userDefaults.removeObject(forKey: customFFmpegKey)
        userDefaults.removeObject(forKey: customFFprobeKey)
        setEngineMode(.auto)
    }
    
    private func resolveBinariesForCurrentMode() -> (ffmpeg: String?, ffprobe: String?, source: FFmpegSource) {
        switch selectedMode {
        case .bundled:
            let f = findUsableBundledBinary(named: "ffmpeg")
            let p = findUsableBundledBinary(named: "ffprobe")
            return (f, p, (f != nil && p != nil) ? .bundled : .missing)
            
        case .homebrew:
            let f = findUsableHomebrewBinary(named: "ffmpeg")
            let p = findUsableHomebrewBinary(named: "ffprobe")
            return (f, p, (f != nil && p != nil) ? .homebrew : .missing)
            
        case .custom:
            let f = userDefaults.string(forKey: customFFmpegKey).flatMap { isUsableExecutable(atPath: $0) ? $0 : nil }
            let p = userDefaults.string(forKey: customFFprobeKey).flatMap { isUsableExecutable(atPath: $0) ? $0 : nil }
            return (f, p, (f != nil && p != nil) ? .custom : .missing)
            
        case .auto:
            // Priority 1: Bundled Engine (matched usable pair)
            if let bf = findUsableBundledBinary(named: "ffmpeg"),
               let bp = findUsableBundledBinary(named: "ffprobe") {
                return (bf, bp, .bundled)
            }
            // Priority 2: Homebrew (matched usable pair)
            if let hf = findUsableHomebrewBinary(named: "ffmpeg"),
               let hp = findUsableHomebrewBinary(named: "ffprobe") {
                return (hf, hp, .homebrew)
            }
            // Priority 3: System PATH (matched usable pair)
            if let sf = findUsableSystemBinary(named: "ffmpeg"),
               let sp = findUsableSystemBinary(named: "ffprobe") {
                return (sf.0, sp.0, sf.1)
            }
            
            // Fallback: mix independently usable binaries if sources differ
            let anyFFmpeg: (String, FFmpegSource)? =
                findUsableBundledBinary(named: "ffmpeg").map { ($0, .bundled) }
                ?? findUsableHomebrewBinary(named: "ffmpeg").map { ($0, .homebrew) }
                ?? findUsableSystemBinary(named: "ffmpeg")
            let anyFFprobe: String? =
                findUsableBundledBinary(named: "ffprobe")
                ?? findUsableHomebrewBinary(named: "ffprobe")
                ?? findUsableSystemBinary(named: "ffprobe")?.0
            if let anyFFmpeg, let anyFFprobe {
                return (anyFFmpeg.0, anyFFprobe, anyFFmpeg.1)
            }
            return (anyFFmpeg?.0, anyFFprobe, .missing)
        }
    }
    
    private func bundledCandidatePaths(named name: String) -> [String] {
        if let override = bundledSearchPathsOverride {
            return override[name] ?? []
        }
        
        var candidates: [String] = []
        // 1. App Bundle Resources (Strata.app/Contents/Resources/bin/name or Resources/name)
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("bin").appendingPathComponent(name).path)
            candidates.append(resourceURL.appendingPathComponent(name).path)
        }
        // 2. Executable parent directory Resources
        let execDir = Bundle.main.bundleURL.deletingLastPathComponent()
        candidates.append(execDir.appendingPathComponent("Resources/bin").appendingPathComponent(name).path)
        // 3. Project working directory (during development)
        let projectBin = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/Strata/Resources/bin")
            .appendingPathComponent(name).path
        candidates.append(projectBin)
        return candidates
    }
    
    private func findUsableBundledBinary(named name: String) -> String? {
        for candidate in bundledCandidatePaths(named: name) where isUsableExecutable(atPath: candidate) {
            return candidate
        }
        return nil
    }
    
    private func findUsableHomebrewBinary(named name: String) -> String? {
        let dirs = homebrewSearchDirsOverride ?? ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if isUsableExecutable(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
    
    private func findUsableSystemBinary(named name: String) -> (String, FFmpegSource)? {
        if let overrideDirs = systemSearchDirsOverride {
            for dir in overrideDirs {
                let candidate = (dir as NSString).appendingPathComponent(name)
                if isUsableExecutable(atPath: candidate) {
                    let src: FFmpegSource = candidate.contains("homebrew") ? .homebrew : .system
                    return (candidate, src)
                }
            }
            return nil
        }
        
        let usrBin = "/usr/bin/\(name)"
        if isUsableExecutable(atPath: usrBin) { return (usrBin, .system) }
        
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.components(separatedBy: ":") where !dir.isEmpty {
                let candidate = (dir as NSString).appendingPathComponent(name)
                if isUsableExecutable(atPath: candidate) {
                    let src: FFmpegSource = candidate.contains("homebrew") ? .homebrew : .system
                    return (candidate, src)
                }
            }
        }
        return nil
    }
    
    private func isUsableExecutable(atPath path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        return verifiedVersion(binaryPath: path) != nil
    }
    
    private func binarySignature(atPath path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return "missing"
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        return "\(mtime):\(size)"
    }
    
    private func verifiedVersion(binaryPath: String) -> String? {
        let sig = binarySignature(atPath: binaryPath)
        probeCacheLock.lock()
        let cached = probeCache[binaryPath]
        probeCacheLock.unlock()
        
        if let cached {
            switch cached {
            case .valid(let cachedSig, let version) where cachedSig == sig:
                return version
            case .invalid(let cachedSig) where cachedSig == sig:
                return nil
            default:
                break
            }
        }
        
        let version = Self.executeVersionProbe(binaryPath: binaryPath)
        probeCacheLock.lock()
        if let version {
            probeCache[binaryPath] = .valid(signature: sig, version: version)
        } else {
            probeCache[binaryPath] = .invalid(signature: sig)
        }
        probeCacheLock.unlock()
        return version
    }
    
    private static func executeVersionProbe(binaryPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["-version"]
        
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }
        
        final class DataBox: @unchecked Sendable {
            var data = Data()
        }
        let box = DataBox()
        let readGroup = DispatchGroup()
        readGroup.enter()
        let readHandle = pipe.fileHandleForReading
        
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            readGroup.leave()
            return nil
        }
        
        // Drain stdout concurrently and wait via DispatchSemaphore instead of Process.waitUntilExit(),
        // which pumps CFRunLoop and can re-enter dispatch_once if triggered during static shared init.
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = readHandle.readDataToEndOfFile()
            readGroup.leave()
        }
        
        let waitResult = exitSemaphore.wait(timeout: .now() + 2.0)
        process.terminationHandler = nil
        if waitResult == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            _ = readGroup.wait(timeout: .now() + 0.5)
            return nil
        }
        
        _ = readGroup.wait(timeout: .now() + 0.5)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            return nil
        }
        guard let output = String(data: box.data, encoding: .utf8) else {
            return nil
        }
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}
