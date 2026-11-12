import Foundation

public struct SmartCutSegmentPlan: Equatable, Sendable {
    public let leadingReencodeRange: MediaTrimRange?
    public let losslessCopyRange: MediaTrimRange?
    public let trailingReencodeRange: MediaTrimRange?
    public let requiresEdgeReencode: Bool
    
    public init(
        leadingReencodeRange: MediaTrimRange?,
        losslessCopyRange: MediaTrimRange?,
        trailingReencodeRange: MediaTrimRange?
    ) {
        self.leadingReencodeRange = leadingReencodeRange
        self.losslessCopyRange = losslessCopyRange
        self.trailingReencodeRange = trailingReencodeRange
        self.requiresEdgeReencode = (leadingReencodeRange != nil) || (trailingReencodeRange != nil)
    }
}

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
    
    // MARK: - v2.0 Frame-Accurate Smart-Cut Foundations (Non-UI)
    
    /// Computes pure Smart-Cut segment boundaries for an arbitrary `[inTime, outTime]` selection given probed IDR keyframes.
    public static func planSmartCutSegments(
        trimRange: MediaTrimRange,
        keyframes: [Double],
        tolerance: Double = 0.002
    ) -> SmartCutSegmentPlan {
        guard trimRange.isValid else {
            return SmartCutSegmentPlan(leadingReencodeRange: nil, losslessCopyRange: nil, trailingReencodeRange: nil)
        }
        let sortedKF = keyframes.filter { $0.isFinite && $0 >= 0 }.sorted()
        let firstCopyKF = sortedKF.first { $0 >= trimRange.inTime - tolerance }
        
        // No IDR keyframe inside selection -> entire trimmed region is re-encoded with matched codec params
        guard let copyStart = firstCopyKF, copyStart <= trimRange.outTime - tolerance else {
            return SmartCutSegmentPlan(
                leadingReencodeRange: trimRange,
                losslessCopyRange: nil,
                trailingReencodeRange: nil
            )
        }
        
        let leadingRange: MediaTrimRange? = (copyStart - trimRange.inTime > tolerance)
            ? MediaTrimRange(inTime: trimRange.inTime, outTime: copyStart)
            : nil
        
        let lastKFInWindow = sortedKF.last { $0 >= copyStart - tolerance && $0 <= trimRange.outTime + tolerance }
        let trailingRange: MediaTrimRange?
        let copyEnd: Double
        if let endKF = lastKFInWindow, endKF > copyStart + tolerance, abs(trimRange.outTime - endKF) > tolerance {
            copyEnd = endKF
            trailingRange = MediaTrimRange(inTime: endKF, outTime: trimRange.outTime)
        } else {
            copyEnd = trimRange.outTime
            trailingRange = nil
        }
        
        let middleCopy = MediaTrimRange(inTime: copyStart, outTime: copyEnd)
        return SmartCutSegmentPlan(
            leadingReencodeRange: leadingRange,
            losslessCopyRange: middleCopy.isValid ? middleCopy : nil,
            trailingReencodeRange: trailingRange
        )
    }
    
    /// Probes localized keyframes surrounding `trimRange` and resolves the Smart-Cut plan for v2.0 Timeline Cutting.
    public static func findSurroundingKeyframes(
        fileURL: URL,
        videoStreamIndex: Int,
        trimRange: MediaTrimRange,
        duration: Double,
        ffprobePath: String
    ) async -> SmartCutSegmentPlan {
        let startWindow = max(0.0, trimRange.inTime - 10.0)
        let leadingKFs = await probeKeyframesInWindow(
            fileURL: fileURL,
            videoStreamIndex: videoStreamIndex,
            windowStart: startWindow,
            windowDuration: 20.0,
            ffprobePath: ffprobePath
        )
        let endWindow = max(0.0, trimRange.outTime - 10.0)
        let trailingKFs = await probeKeyframesInWindow(
            fileURL: fileURL,
            videoStreamIndex: videoStreamIndex,
            windowStart: endWindow,
            windowDuration: min(20.0, max(1.0, duration - endWindow)),
            ffprobePath: ffprobePath
        )
        let merged = Array(Set(leadingKFs + trailingKFs)).sorted()
        return planSmartCutSegments(trimRange: trimRange, keyframes: merged)
    }
    
    /// Builds codec-matched edge re-encode arguments for an open-GOP Smart-Cut boundary slice.
    public static func buildSmartCutEdgeArguments(
        sourceURL: URL,
        videoTrack: MediaTrack,
        edgeRange: MediaTrimRange,
        isLeadingEdge: Bool,
        isMP4Like: Bool,
        outputURL: URL
    ) -> [String] {
        var args: [String] = [
            "-y", "-hide_banner",
            "-ss", String(format: "%.6f", edgeRange.inTime),
            "-i", sourceURL.path,
            "-t", String(format: "%.6f", edgeRange.duration),
            "-map", "0:\(videoTrack.streamIndex)",
            "-an", "-sn", "-dn"
        ]
        
        let lowerCodec = videoTrack.codecName.lowercased()
        let isHEVC = lowerCodec == "hevc" || lowerCodec == "h265" || lowerCodec == "hev1" || lowerCodec == "hvc1"
        args += ["-c:v:0", isHEVC ? "hevc_videotoolbox" : "h264_videotoolbox"]
        args += ["-q:v:0", "\(VideoQualityPreset.balanced.qualityValue)", "-realtime:v:0", "0", "-spatial_aq:v:0", "1"]
        
        if let profile = videoTrack.profile?.lowercased().replacingOccurrences(of: " ", with: ""), !profile.isEmpty {
            if isHEVC {
                if ["main", "main10", "main42210"].contains(profile) {
                    args += ["-profile:v:0", profile]
                }
            } else if ["baseline", "main", "high"].contains(profile) {
                args += ["-profile:v:0", profile]
            }
        }
        
        if let level = videoTrack.codecLevel, level > 0, let formatted = videoTrack.codecLevelDisplay {
            args += ["-level:v:0", formatted]
        }
        if let p = videoTrack.colorPrimaries, !p.isEmpty {
            args += ["-color_primaries:v:0", p]
        }
        if let t = videoTrack.colorTransfer, !t.isEmpty {
            args += ["-color_trc:v:0", t]
        }
        if let m = videoTrack.colorSpace, !m.isEmpty {
            args += ["-colorspace:v:0", m]
        }
        if let tb = videoTrack.timeBase, !tb.isEmpty {
            args += ["-video_track_timescale:v:0", tb.components(separatedBy: "/").last ?? "90000"]
        }
        
        // Stitch alignment flags verified in FFmpeg 9.0.2 VideoToolbox
        args += isLeadingEdge ? ["-frames_after:v:0", "1"] : ["-frames_before:v:0", "1"]
        let outExt = outputURL.pathExtension.lowercased()
        if outExt == "ts" || outExt == "m2ts" {
            args += ["-bsf:v:0", "dump_extra", "-f", "mpegts"]
        } else if isHEVC && isMP4Like {
            args += ["-tag:v:0", "hvc1"]
        }
        args.append(outputURL.path)
        return args
    }
    
    /// Builds stitch arguments for concatenating v2.0 Smart-Cut MPEG-TS / Annex-B edge + copy slices.
    public static func buildSmartCutStitchArguments(
        concatListURL: URL,
        isHEVC: Bool,
        isMP4Like: Bool,
        outputURL: URL
    ) -> [String] {
        var args: [String] = [
            "-y", "-hide_banner",
            "-f", "concat", "-safe", "0", "-i", concatListURL.path,
            "-c", "copy",
            "-bsf:v:0", "dump_extra",
            "-avoid_negative_ts", "make_zero"
        ]
        if isHEVC && isMP4Like {
            args += ["-tag:v:0", "hvc1"]
        }
        args.append(outputURL.path)
        return args
    }
}
