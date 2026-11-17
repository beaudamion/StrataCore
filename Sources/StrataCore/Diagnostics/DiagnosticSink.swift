import Foundation

/// Central thread-safe diagnostic hub in StrataCore.
/// Pure Foundation actor with zero dependencies on AppKit, SwiftUI, or OSLog.
public actor DiagnosticSink {
    public static let shared = DiagnosticSink()
    
    private var eventContinuations: [UUID: AsyncStream<DiagnosticEvent>.Continuation] = [:]
    private var snapshotContinuations: [UUID: AsyncStream<FailedJobSnapshot>.Continuation] = [:]
    private var recentFailedJobs: [FailedJobSnapshot] = []
    private let maxRecentJobs: Int = 10
    
    public init() {}
    
    // MARK: - Event Publishing
    
    /// Publish a diagnostic event to all active observers.
    public func emit(_ event: DiagnosticEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }
    
    /// Nonisolated convenience helper to emit a diagnostic event from synchronous or detached contexts.
    public nonisolated func emitDetached(_ event: DiagnosticEvent) {
        Task {
            await self.emit(event)
        }
    }
    
    /// Record a failed job snapshot and broadcast it to active observers.
    public func recordFailedJob(_ snapshot: FailedJobSnapshot) {
        recentFailedJobs.append(snapshot)
        if recentFailedJobs.count > maxRecentJobs {
            recentFailedJobs.removeFirst()
        }
        
        // Also emit a corresponding error event for general loggers
        let summary = "Job failed: [\(snapshot.executableName)] \(snapshot.operation) with exit code \(snapshot.exitCode)"
        let event = DiagnosticEvent(
            timestamp: snapshot.timestamp,
            category: .remux,
            level: .error,
            message: summary,
            metadata: [
                "jobId": snapshot.id.uuidString,
                "executable": snapshot.executableName,
                "exitCode": "\(snapshot.exitCode)",
                "operation": snapshot.operation
            ]
        )
        emit(event)
        
        for continuation in snapshotContinuations.values {
            continuation.yield(snapshot)
        }
    }
    
    // MARK: - Snapshot Queries
    
    /// Retrieve the in-memory history of recent failed job snapshots.
    public func getRecentFailedJobs() -> [FailedJobSnapshot] {
        return recentFailedJobs
    }
    
    /// Clear in-memory failed job history.
    public func clearFailedJobs() {
        recentFailedJobs.removeAll(keepingCapacity: true)
    }
    
    // MARK: - Subscriptions
    
    /// Subscribe to the stream of diagnostic events.
    public func subscribeEvents() -> AsyncStream<DiagnosticEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeEventContinuation(id: id)
                }
            }
            self.eventContinuations[id] = continuation
        }
    }
    
    /// Subscribe to the stream of failed job snapshots.
    public func subscribeFailedJobs() -> AsyncStream<FailedJobSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeSnapshotContinuation(id: id)
                }
            }
            self.snapshotContinuations[id] = continuation
        }
    }
    
    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }
    
    private func removeSnapshotContinuation(id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }
}
