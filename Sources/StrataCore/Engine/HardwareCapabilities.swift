import Foundation
import IOKit

// MARK: - Segmented Encoding Mode

public enum SegmentedEncodingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case two = "two"
    case three = "three"
    case four = "four"
    case off = "off"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .auto: return "Auto (Open Engines)"
        case .two: return "Manual: 2 Segments"
        case .three: return "Manual: 3 Segments"
        case .four: return "Manual: 4 Segments"
        case .off: return "Off (Single Stream)"
        }
    }
    
    public var fixedSegmentCount: Int? {
        switch self {
        case .auto: return nil
        case .two: return 2
        case .three: return 3
        case .four: return 4
        case .off: return 1
        }
    }
}

public enum MediaEngineFamily: String, Sendable {
    case ave
    case proRes
}

// MARK: - Hardware Media Capabilities

public struct HardwareMediaCapabilities: Equatable, Sendable {
    public let chipName: String
    public let cpuCoreCount: Int
    public let isAppleSilicon: Bool
    public let h264HEVCEngineCount: Int
    public let proResEngineCount: Int
    public let activeAVEEnginesInUse: Int
    public let activeProResEnginesInUse: Int
    
    public init(
        chipName: String,
        cpuCoreCount: Int,
        isAppleSilicon: Bool,
        h264HEVCEngineCount: Int,
        proResEngineCount: Int,
        activeAVEEnginesInUse: Int = 0,
        activeProResEnginesInUse: Int = 0
    ) {
        self.chipName = chipName
        self.cpuCoreCount = cpuCoreCount
        self.isAppleSilicon = isAppleSilicon
        self.h264HEVCEngineCount = max(0, h264HEVCEngineCount)
        self.proResEngineCount = max(0, proResEngineCount)
        self.activeAVEEnginesInUse = max(0, activeAVEEnginesInUse)
        self.activeProResEnginesInUse = max(0, activeProResEnginesInUse)
    }
    
    public var openAVEEngines: Int {
        max(0, h264HEVCEngineCount - activeAVEEnginesInUse)
    }
    
    public var openProResEngines: Int {
        max(0, proResEngineCount - activeProResEnginesInUse)
    }
    
    public func totalEngines(for family: MediaEngineFamily) -> Int {
        switch family {
        case .ave: return h264HEVCEngineCount
        case .proRes: return proResEngineCount
        }
    }
    
    public func openEngines(for family: MediaEngineFamily) -> Int {
        switch family {
        case .ave: return openAVEEngines
        case .proRes: return openProResEngines
        }
    }
    
    public func activeEngines(for family: MediaEngineFamily) -> Int {
        switch family {
        case .ave: return activeAVEEnginesInUse
        case .proRes: return activeProResEnginesInUse
        }
    }
    
    public var statusSummary: String {
        guard isAppleSilicon else {
            return "\(chipName) • Software / Platform VideoToolbox"
        }
        let aveText = h264HEVCEngineCount == 1
            ? "1 H.264/HEVC (\(openAVEEngines) idle)"
            : "\(h264HEVCEngineCount) H.264/HEVC (\(openAVEEngines) idle)"
        let proResText = proResEngineCount == 0
            ? "0 ProRes HW"
            : "\(proResEngineCount) ProRes (\(openProResEngines) idle)"
        return "\(chipName) • \(aveText) • \(proResText)"
    }
}

// MARK: - Segmentation Decision

public struct SegmentationDecision: Equatable, Sendable {
    public let segmentCount: Int
    public let notice: String?
    public let engineFamily: MediaEngineFamily?
    
    public var isSegmented: Bool {
        segmentCount >= 2
    }
    
    public init(segmentCount: Int, notice: String? = nil, engineFamily: MediaEngineFamily? = nil) {
        self.segmentCount = max(1, segmentCount)
        self.notice = notice
        self.engineFamily = engineFamily
    }
}

// MARK: - Internal Session Coordinator

public actor HardwareSessionCoordinator {
    public static let shared = HardwareSessionCoordinator()
    
    private var activeAVEConsumers: Int = 0
    private var activeProResConsumers: Int = 0
    
    public init() {}
    
    public func activeCounts() -> (ave: Int, proRes: Int) {
        (activeAVEConsumers, activeProResConsumers)
    }
    
    public func acquire(family: MediaEngineFamily, count: Int) {
        let clamped = max(0, count)
        switch family {
        case .ave:
            activeAVEConsumers += clamped
        case .proRes:
            activeProResConsumers += clamped
        }
    }
    
    public func release(family: MediaEngineFamily, count: Int) {
        let clamped = max(0, count)
        switch family {
        case .ave:
            activeAVEConsumers = max(0, activeAVEConsumers - clamped)
        case .proRes:
            activeProResConsumers = max(0, activeProResConsumers - clamped)
        }
    }
}

// MARK: - Hardware Capability & Policy Resolver

public enum HardwareCapabilities {
    /// Detects chip topology via sysctl and physical/active Media Engine state via IOKit.
    public static func detect(
        internalActiveAVE: Int = 0,
        internalActiveProRes: Int = 0
    ) -> HardwareMediaCapabilities {
        let chipName = sysctlString("machdep.cpu.brand_string") ?? "Mac"
        let cpuCount = Int(sysctlInt32("hw.ncpu") ?? Int32(ProcessInfo.processInfo.processorCount))
        let arm64Flag = (sysctlInt32("hw.optional.arm64") ?? 0) == 1
        #if arch(arm64)
        let isAppleSilicon = true || arm64Flag || chipName.localizedCaseInsensitiveContains("Apple")
        #else
        let isAppleSilicon = arm64Flag || chipName.localizedCaseInsensitiveContains("Apple")
        #endif
        
        let topology = queryIODeviceTreeEngineCounts()
        let fallbackCounts = fallbackEngineCounts(chipName: chipName, isAppleSilicon: isAppleSilicon)
        
        let aveTotal = topology.ave > 0 ? topology.ave : fallbackCounts.ave
        let proResTotal: Int
        if !isAppleSilicon {
            proResTotal = 0
        } else if topology.proRes > 0 {
            proResTotal = topology.proRes
        } else if topology.foundAnyMediaTreeNode {
            // If IODeviceTree was readable and found AVE nodes but 0 apr nodes (e.g., M1 Base), respect 0.
            proResTotal = 0
        } else {
            proResTotal = fallbackCounts.proRes
        }
        
        // Live system-wide active VideoToolbox / ProRes hardware sessions
        let aveExternal = countMatchingIOKitServices(classNames: ["AppleAVE2UserClient", "AppleAVEUserClient"])
        let proResExternal = countMatchingIOKitServices(classNames: ["AppleProResUserClient", "AppleProResHWUserClient"])
        
        return HardwareMediaCapabilities(
            chipName: chipName,
            cpuCoreCount: cpuCount,
            isAppleSilicon: isAppleSilicon,
            h264HEVCEngineCount: aveTotal,
            proResEngineCount: proResTotal,
            activeAVEEnginesInUse: max(aveExternal, internalActiveAVE),
            activeProResEnginesInUse: max(proResExternal, internalActiveProRes)
        )
    }
    
    /// Async helper that incorporates Strata's own active HardwareSessionCoordinator reservations.
    public static func detectWithCoordinator() async -> HardwareMediaCapabilities {
        let internalCounts = await HardwareSessionCoordinator.shared.activeCounts()
        return detect(internalActiveAVE: internalCounts.ave, internalActiveProRes: internalCounts.proRes)
    }
    
    /// Pure helper for resolving silicon-tier fallback counts from a macOS CPU brand string.
    public static func fallbackEngineCounts(chipName: String, isAppleSilicon: Bool) -> (ave: Int, proRes: Int) {
        guard isAppleSilicon else { return (0, 0) }
        let lower = chipName.lowercased()
        let tierCount: Int
        if lower.contains("ultra") {
            tierCount = 4
        } else if lower.contains("max") {
            tierCount = 2
        } else {
            tierCount = 1
        }
        
        // M1 Base/Air lacks a dedicated Apple ProRes hardware engine (`apr`); M1 Pro/Max/Ultra & M2+ include ProRes hardware.
        let isM1Base = lower.contains("m1") && !lower.contains("pro") && !lower.contains("max") && !lower.contains("ultra")
        let proResCount = isM1Base ? 0 : tierCount
        return (tierCount, proResCount)
    }
    
    /// Resolves whether a single-file export should use segmented parallel workers, and emits any non-blocking notice.
    public static func resolveSegmentation(
        for file: MediaFile,
        options: RemuxOptions,
        capabilities: HardwareMediaCapabilities
    ) -> SegmentationDecision {
        guard options.useHardwareAcceleration else {
            return SegmentationDecision(segmentCount: 1, notice: nil, engineFamily: nil)
        }
        
        let selectedTracks = file.tracks.filter { $0.isSelected }
        let selectedVideoTracks = selectedTracks.filter { $0.mediaType == .video }
        
        guard selectedVideoTracks.count == 1,
              let video = selectedVideoTracks.first,
              !video.isExternal,
              video.action != .copy,
              options.targetContainer != .webm else {
            return SegmentationDecision(segmentCount: 1, notice: nil, engineFamily: nil)
        }
        
        let family: MediaEngineFamily
        let codecLabel: String
        switch video.action {
        case .transcodeH264_VT:
            if video.videoConfig.multiPass {
                return SegmentationDecision(segmentCount: 1, notice: nil, engineFamily: nil)
            }
            family = .ave
            codecLabel = "H.264"
        case .transcodeHEVC_VT:
            let profile = video.videoConfig.profile?.lowercased()
            if video.videoConfig.multiPass || profile == "main422" {
                return SegmentationDecision(segmentCount: 1, notice: nil, engineFamily: nil)
            }
            family = .ave
            codecLabel = "HEVC"
        case .transcodeProRes:
            family = .proRes
            codecLabel = "ProRes"
        default:
            return SegmentationDecision(segmentCount: 1, notice: nil, engineFamily: nil)
        }
        
        let totalEngines = capabilities.totalEngines(for: family)
        let openEngines = capabilities.openEngines(for: family)
        let activeBusy = capabilities.activeEngines(for: family)
        
        // Notice when no dedicated hardware engine exists for the requested codec
        if totalEngines == 0 {
            return SegmentationDecision(
                segmentCount: 1,
                notice: "No dedicated \(codecLabel) hardware engine on this Mac — using software fallback.",
                engineFamily: family
            )
        }
        
        // Determine target segment count from user preference & duration eligibility
        let meetsDuration = file.duration >= options.minSegmentationDuration
        
        switch options.segmentedEncodingMode {
        case .off:
            let notice: String? = openEngines == 0
                ? "Hardware Media Engines busy — running single-stream mode."
                : nil
            return SegmentationDecision(segmentCount: 1, notice: notice, engineFamily: family)
            
        case .two, .three, .four:
            let requested = options.segmentedEncodingMode.fixedSegmentCount ?? 1
            guard meetsDuration else {
                let notice = openEngines == 0
                    ? "Hardware Media Engines busy — running single-stream mode."
                    : nil
                return SegmentationDecision(segmentCount: 1, notice: notice, engineFamily: family)
            }
            let durationSafeCount = max(1, min(requested, Int(floor(file.duration / 3.0))))
            let notice: String? = openEngines == 0
                ? "Hardware Media Engines busy — time-sharing \(durationSafeCount)× segments."
                : nil
            return SegmentationDecision(segmentCount: durationSafeCount, notice: notice, engineFamily: family)
            
        case .auto:
            if openEngines == 0 {
                return SegmentationDecision(
                    segmentCount: 1,
                    notice: "All \(totalEngines) hardware Media Engines busy — running single-stream mode.",
                    engineFamily: family
                )
            }
            
            guard meetsDuration else {
                if totalEngines >= 2 && openEngines == 1 && activeBusy > 0 {
                    return SegmentationDecision(
                        segmentCount: 1,
                        notice: "\(activeBusy) of \(totalEngines) hardware Media Engines in use — encoding on 1 idle engine.",
                        engineFamily: family
                    )
                }
                return SegmentationDecision(segmentCount: 1, notice: nil, engineFamily: family)
            }
            
            if openEngines >= 2 {
                let maxSegments = min(openEngines, 4)
                let durationSafeCount = max(1, min(maxSegments, Int(floor(file.duration / 3.0))))
                return SegmentationDecision(segmentCount: durationSafeCount, notice: nil, engineFamily: family)
            } else {
                // 1 open engine (either Base/Pro chip with 1 engine total, or Max with 1 engine busy elsewhere)
                let notice: String? = (totalEngines >= 2 && activeBusy > 0)
                    ? "\(activeBusy) of \(totalEngines) hardware Media Engines in use — running single-stream on idle engine."
                    : nil
                return SegmentationDecision(segmentCount: 1, notice: notice, engineFamily: family)
            }
        }
    }
    
    // MARK: - Private IOKit & sysctl Helpers
    
    private static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
    
    private static func queryIODeviceTreeEngineCounts() -> (ave: Int, proRes: Int, foundAnyMediaTreeNode: Bool) {
        var iterator: io_iterator_t = 0
        let kr = IORegistryCreateIterator(
            kIOMainPortDefault,
            kIODeviceTreePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        )
        guard kr == KERN_SUCCESS else {
            return (0, 0, false)
        }
        defer { IOObjectRelease(iterator) }
        
        var aveCount = 0
        var aprCount = 0
        var foundAnyMedia = false
        
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            
            let deviceType = stringProperty(entry: entry, key: "device_type")
            if deviceType == "ave" {
                aveCount += 1
                foundAnyMedia = true
                continue
            }
            if deviceType == "apr" {
                aprCount += 1
                foundAnyMedia = true
                continue
            }
            if deviceType == "avd" {
                foundAnyMedia = true
            }
        }
        
        return (aveCount, aprCount, foundAnyMedia)
    }
    
    private static func stringProperty(entry: io_registry_entry_t, key: String) -> String? {
        guard let cfVal = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        if let str = cfVal as? String {
            return str.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        }
        if let data = cfVal as? Data {
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        }
        return nil
    }
    
    private static func countMatchingIOKitServices(classNames: [String]) -> Int {
        var total = 0
        for className in classNames {
            guard let matching = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
            guard kr == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            
            while case let service = IOIteratorNext(iterator), service != 0 {
                IOObjectRelease(service)
                total += 1
            }
        }
        return total
    }
}
