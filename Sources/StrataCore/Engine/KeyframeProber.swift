import Foundation

public struct VideoSegmentBoundary: Equatable, Sendable {
    public let index: Int
    /// Accurate input `-ss` timestamp slightly before `exactStartPTS` (nil for chunk 0).
    public let seekTime: Double?
    public let exactStartPTS: Double
    public let exactEndPTS: Double?
    public let expectedDuration: Double
    
    public init(
        index: Int,
        seekTime: Double?,
        exactStartPTS: Double,
        exactEndPTS: Double?,
        expectedDuration: Double
    ) {
        self.index = index
        self.seekTime = seekTime
        self.exactStartPTS = exactStartPTS
        self.exactEndPTS = exactEndPTS
        self.expectedDuration = max(0, expectedDuration)
    }
}

public enum KeyframeProber {
    private static let boundarySafetyMargin: Double = 0.0005
    
    /// Probes keyframe cut boundaries near `segmentCount - 1` evenly spaced target timestamps
    /// using fast localized `-read_intervals` windows in `ffprobe`.
    public static func probeBoundaries(
        fileURL: URL,
        videoStreamIndex: Int,
        duration: Double,
        startTime: Double = 0.0,
        segmentCount: Int,
        ffprobePath: String,
        minimumChunkDuration: Double = 2.5
    ) async -> [VideoSegmentBoundary] {
        guard segmentCount >= 2, duration > minimumChunkDuration * 2.0 else {
            return []
        }
        
        let streamStart = max(0.0, startTime)
        let streamEnd = streamStart + duration
        var selectedCuts: [Double] = []
        
        for i in 1..<segmentCount {
            let target = streamStart + (duration * (Double(i) / Double(segmentCount)))
            let minAllowed = (selectedCuts.last ?? streamStart) + minimumChunkDuration
            let maxAllowed = streamEnd - minimumChunkDuration
            guard minAllowed < maxAllowed else { continue }
            
            // Query +/- 12s around target first; widen to +/- 45s if keyframes are very sparse
            let halfWindow = 12.0
            var candidates = await probeKeyframesInWindow(
                fileURL: fileURL,
                videoStreamIndex: videoStreamIndex,
                windowStart: max(streamStart, target - halfWindow),
                windowDuration: halfWindow * 2.0,
                ffprobePath: ffprobePath
            )
            
            var chosen = bestKeyframe(in: candidates, near: target, minAllowed: minAllowed, maxAllowed: maxAllowed)
            if chosen == nil {
                candidates = await probeKeyframesInWindow(
                    fileURL: fileURL,
                    videoStreamIndex: videoStreamIndex,
                    windowStart: max(streamStart, target - 45.0),
                    windowDuration: 90.0,
                    ffprobePath: ffprobePath
                )
                chosen = bestKeyframe(in: candidates, near: target, minAllowed: minAllowed, maxAllowed: maxAllowed)
            }
            
            if let cut = chosen {
                selectedCuts.append(cut)
            }
        }
        
        return buildBoundaries(
            cutPoints: selectedCuts,
            streamStart: streamStart,
            streamEnd: streamEnd,
            minimumChunkDuration: minimumChunkDuration
        )
    }
    
    /// Builds finalized `[VideoSegmentBoundary]` from sorted cut timestamps, dropping degenerate cuts.
    public static func buildBoundaries(
        cutPoints: [Double],
        streamStart: Double,
        streamEnd: Double,
        minimumChunkDuration: Double = 2.5
    ) -> [VideoSegmentBoundary] {
        let sortedUnique = cutPoints
            .filter { $0 > streamStart + minimumChunkDuration && $0 < streamEnd - minimumChunkDuration }
            .sorted()
        
        var filteredCuts: [Double] = []
        for pt in sortedUnique {
            if let last = filteredCuts.last, (pt - last) < minimumChunkDuration {
                continue
            }
            filteredCuts.append(pt)
        }
        
        guard !filteredCuts.isEmpty else {
            return []
        }
        
        let allStarts = [streamStart] + filteredCuts
        let allEnds: [Double?] = filteredCuts.map { Optional($0) } + [nil]
        
        var result: [VideoSegmentBoundary] = []
        result.reserveCapacity(allStarts.count)
        
        for idx in 0..<allStarts.count {
            let startPTS = allStarts[idx]
            let endPTS = allEnds[idx]
            let seek: Double? = (idx == 0) ? nil : max(0.0, startPTS - boundarySafetyMargin)
            let expectedDur: Double
            if let end = endPTS {
                let effectiveStart = seek ?? startPTS
                expectedDur = max(0.0, (end - boundarySafetyMargin) - effectiveStart)
            } else {
                expectedDur = max(0.0, streamEnd - startPTS)
            }
            
            result.append(VideoSegmentBoundary(
                index: idx,
                seekTime: seek,
                exactStartPTS: startPTS,
                exactEndPTS: endPTS,
                expectedDuration: expectedDur
            ))
        }
        
        return result
    }
    
    /// Parses `ffprobe -show_entries packet=pts_time,flags -of csv=p=0` output for keyframe `pts_time` values.
    public static func parseKeyframeTimestamps(fromCSV output: String) -> [Double] {
        var keyframes: [Double] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let fields = trimmed.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let flags = fields[1]
            guard flags.contains("K") else { continue }
            if let pts = Double(fields[0].trimmingCharacters(in: .whitespacesAndNewlines)),
               pts.isFinite, pts >= 0 {
                keyframes.append(pts)
            }
        }
        return Array(Set(keyframes)).sorted()
    }
    
    private static func bestKeyframe(
        in candidates: [Double],
        near target: Double,
        minAllowed: Double,
        maxAllowed: Double
    ) -> Double? {
        let valid = candidates.filter { $0 >= minAllowed && $0 <= maxAllowed }
        return valid.min(by: { abs($0 - target) < abs($1 - target) })
    }
    
    private static func probeKeyframesInWindow(
        fileURL: URL,
        videoStreamIndex: Int,
        windowStart: Double,
        windowDuration: Double,
        ffprobePath: String
    ) async -> [Double] {
        let intervalArg = String(format: "%.3f%%+%.3f", windowStart, windowDuration)
        let args = [
            "-v", "error",
            "-read_intervals", intervalArg,
            "-select_streams", "\(videoStreamIndex)",
            "-show_entries", "packet=pts_time,flags",
            "-of", "csv=p=0",
            fileURL.path
        ]
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = args
        
        let stdoutPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        
        let (terminationStream, terminationContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { terminated in
            terminated.terminationHandler = nil
            terminationContinuation.yield(terminated.terminationStatus)
            terminationContinuation.finish()
        }
        
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            terminationContinuation.finish()
            return []
        }
        
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        var status: Int32 = -1
        for await exitCode in terminationStream {
            status = exitCode
            break
        }
        process.terminationHandler = nil
        guard status == 0, let text = String(data: data, encoding: .utf8) else {
            return []
        }
        
        return parseKeyframeTimestamps(fromCSV: text)
    }
}
