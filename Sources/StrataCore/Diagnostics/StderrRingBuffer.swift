import Foundation

/// Thread-safe circular stderr buffer that preserves critical execution startup telemetry
/// and terminal error traces while deduplicating high-cadence progress updates.
public final class StderrRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maxPreludeLines: Int
    private let maxTailLines: Int
    
    private var prelude: [String] = []
    private var tail: [String] = []
    private var latestProgressLine: String?
    
    public init(maxPreludeLines: Int = 25, maxTailLines: Int = 175) {
        self.maxPreludeLines = maxPreludeLines
        self.maxTailLines = maxTailLines
    }
    
    /// Append a single stderr line, intelligently categorizing it into startup prelude,
    /// deduplicated progress snapshot, or failure tail.
    public func append(line: String) {
        lock.lock()
        defer { lock.unlock() }
        
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // Detect FFmpeg progress updates (e.g. "frame=  120 fps= 60 ... speed=1.2x")
        if isProgressLine(trimmed) {
            latestProgressLine = trimmed
            return
        }
        
        if prelude.count < maxPreludeLines {
            prelude.append(trimmed)
        } else {
            if tail.count >= maxTailLines {
                tail.removeFirst()
            }
            tail.append(trimmed)
        }
    }
    
    /// Returns the aggregated diagnostic snapshot containing the execution prelude,
    /// the last progress state (if any), and the terminal error tail.
    public func snapshotLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        
        var result: [String] = []
        result.reserveCapacity(prelude.count + (latestProgressLine != nil ? 1 : 0) + tail.count)
        result.append(contentsOf: prelude)
        if let progress = latestProgressLine {
            result.append("[Last Progress Update] \(progress)")
        }
        result.append(contentsOf: tail)
        return result
    }
    
    /// Clears all buffered lines.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        prelude.removeAll(keepingCapacity: true)
        tail.removeAll(keepingCapacity: true)
        latestProgressLine = nil
    }
    
    // MARK: - Private Helpers
    
    private func isProgressLine(_ line: String) -> Bool {
        if line.hasPrefix("frame=") { return true }
        if line.contains("fps=") && line.contains("speed=") { return true }
        if line.hasPrefix("size=") && line.contains("time=") && line.contains("bitrate=") { return true }
        return false
    }
}
