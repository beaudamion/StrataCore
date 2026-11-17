import Testing
import Foundation
@testable import StrataCore

@Suite("Diagnostic Engine & Event Hub Tests")
struct DiagnosticsTests {
    
    @Test("StderrRingBuffer Prelude, Progress Deduplication, and Failure Tail")
    func testStderrRingBufferBehavior() {
        let buffer = StderrRingBuffer(maxPreludeLines: 25, maxTailLines: 175)
        
        // 1. Emit 30 initial startup/configuration lines
        for i in 1...30 {
            buffer.append(line: "startup_line_\(i)")
        }
        
        // 2. Emit 1,000 continuous progress lines
        for f in 1...1000 {
            buffer.append(line: "frame=  \(f) fps= 60.0 q=0.0 size= 512kB time=00:00:10.00 bitrate= 1000.0kbits/s speed=2.0x")
        }
        
        // 3. Emit 200 error and termination lines
        for e in 1...200 {
            buffer.append(line: "error_trace_line_\(e)")
        }
        
        let lines = buffer.snapshotLines()
        
        // Expect: 25 prelude lines + 1 latest progress line + 175 tail lines = 201 total lines
        #expect(lines.count == 201)
        
        // First line is startup_line_1, 25th is startup_line_25
        #expect(lines.first == "startup_line_1")
        #expect(lines[24] == "startup_line_25")
        
        // 26th line is the single deduplicated progress update (latest frame= 1000)
        #expect(lines[25].contains("[Last Progress Update]"))
        #expect(lines[25].contains("frame=  1000"))
        
        // Tail contains the last 175 error lines (from error_trace_line_26 to error_trace_line_200)
        #expect(lines[26] == "error_trace_line_26")
        #expect(lines.last == "error_trace_line_200")
        
        // Test clear
        buffer.clear()
        #expect(buffer.snapshotLines().isEmpty)
    }
    
    @Test("DiagnosticSink Event Subscription and Emission")
    func testDiagnosticSinkPubSub() async {
        let sink = DiagnosticSink()
        
        let stream = await sink.subscribeEvents()
        var iterator = stream.makeAsyncIterator()
        
        let testEvent = DiagnosticEvent(
            category: .videoToolbox,
            level: .warning,
            message: "Test VT fallback event",
            metadata: ["reason": "hardware_contention"]
        )
        
        await sink.emit(testEvent)
        
        let received = await iterator.next()
        #expect(received != nil)
        #expect(received?.message == "Test VT fallback event")
        #expect(received?.category == .videoToolbox)
        #expect(received?.level == .warning)
        #expect(received?.metadata["reason"] == "hardware_contention")
    }
    
    @Test("DiagnosticSink Failed Job Snapshot Ring Buffer Retention")
    func testFailedJobSnapshotRingBuffer() async {
        let sink = DiagnosticSink()
        await sink.clearFailedJobs()
        
        // Record 15 failed jobs (buffer limit is 10)
        for i in 1...15 {
            let snapshot = FailedJobSnapshot(
                operation: "Test Job \(i)",
                executableName: "ffmpeg",
                arguments: ["-i", "input_\(i).mkv"],
                exitCode: Int32(i),
                stderrTail: ["Failed on job \(i)"]
            )
            await sink.recordFailedJob(snapshot)
        }
        
        let recent = await sink.getRecentFailedJobs()
        #expect(recent.count == 10)
        
        // First retained job should be job 6, last should be job 15
        #expect(recent.first?.operation == "Test Job 6")
        #expect(recent.last?.operation == "Test Job 15")
        #expect(recent.last?.exitCode == 15)
        
        await sink.clearFailedJobs()
        let cleared = await sink.getRecentFailedJobs()
        #expect(cleared.isEmpty)
    }
    
    @Test("Diagnostic Models JSON Codable Serialization")
    func testDiagnosticModelsCodable() throws {
        let event = DiagnosticEvent(
            category: .probe,
            level: .error,
            message: "Corrupt container header",
            metadata: ["container": "matroska"]
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let eventData = try encoder.encode(event)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedEvent = try decoder.decode(DiagnosticEvent.self, from: eventData)
        
        #expect(decodedEvent.id == event.id)
        #expect(decodedEvent.category == .probe)
        #expect(decodedEvent.level == .error)
        #expect(decodedEvent.message == "Corrupt container header")
        #expect(decodedEvent.metadata["container"] == "matroska")
        
        let snapshot = FailedJobSnapshot(
            operation: "Transcode",
            executableName: "ffmpeg",
            arguments: ["-i", "test.mp4", "-c:v", "hevc_videotoolbox", "out.mp4"],
            exitCode: 1,
            stderrTail: ["[hevc_videotoolbox @ 0x...] Error: -12915"],
            probeSummary: "Video: HEVC, Audio: AAC",
            osStatusError: -12915,
            technicalDetails: "Session allocation failed"
        )
        let snapshotData = try encoder.encode(snapshot)
        let decodedSnapshot = try decoder.decode(FailedJobSnapshot.self, from: snapshotData)
        
        #expect(decodedSnapshot.id == snapshot.id)
        #expect(decodedSnapshot.exitCode == 1)
        #expect(decodedSnapshot.osStatusError == -12915)
        #expect(decodedSnapshot.arguments.count == 5)
        #expect(decodedSnapshot.stderrTail.first?.contains("-12915") == true)
    }
    
    @Test("DiagnosticSink EmitDetached Nonisolated Convenience")
    func testDiagnosticSinkEmitDetached() async {
        let sink = DiagnosticSink()
        let stream = await sink.subscribeEvents()
        var iterator = stream.makeAsyncIterator()
        
        sink.emitDetached(DiagnosticEvent(
            category: .probe,
            level: .info,
            message: "Detached probe event"
        ))
        
        let received = await iterator.next()
        #expect(received?.message == "Detached probe event")
        #expect(received?.category == .probe)
    }
}
